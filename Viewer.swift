import AppKit
import AVFoundation
import Carbon.HIToolbox
import Network

final class StudioViewer {
    // Input receipts reuse the sender's ordered, eight-byte keepalive echo.
    private static let inputReceiptMarker: UInt32 = 0x434C494B
    private static let motionReceiptSpacing: DispatchTimeInterval = .milliseconds(120)
    private static let connectionDelayMS = 600
    private var inputSequence: UInt32 = 0
    private var sentInputCount: UInt64 = 0
    private var pendingPointer: Input?
    private var pointerWork: DispatchWorkItem?
    private var nextPointerTime = DispatchTime(uptimeNanoseconds: 0)
    private var receiptDisplays: Set<UInt32> = []
    private var receiptWork: DispatchWorkItem?
    private var nextMotionReceipt = DispatchTime(uptimeNanoseconds: 0)
    private var heartbeatSentMS: UInt64?
    private var heartbeatWatch: DispatchWorkItem?
    private var connectionDelayed = false

    private struct VideoReceipt {
        var bytes: UInt64 = 0
        var changed = false
        var needsKeyframe = false
        var requests = 0
        var lastRequestMS: UInt64?
    }

    private var wire: Wire?
    private var receipts: [UInt32: VideoReceipt] = [:]
    private var feedbackWork: DispatchWorkItem?
    private var recoveryWork: DispatchWorkItem?
    private var tunnel: RelayTunnel?
    private var profile: ReceiverProfile?
    private var directTrials: [Wire] = []
    private var directTimeout: DispatchWorkItem?
    private var handoffRelay: Wire?
    private(set) var connectionPath: ConnectionPath = .relay
    private var windows: [UInt32: RemoteWindow] = [:]
    private var views: [UInt32: RemoteView] = [:]
    private weak var receiverMode: ReceiverMode?
    private var timer: DispatchSourceTimer?
    private var lastSeen = Date()
    private var sawScreens = false
    private var suppressFinish = false
    private var waitingForApproval = false
    private var reportAvailable = false
    private var lastReportAt = Date()
    var diagnosticsEnabled = true
    var onResolutionRequested: ((ReceiverResolution) -> Void)?
    var remoteTuningAllowed = false
    private(set) var diagnosticSession = UUID()
    var resolution: ReceiverResolution = .medium
    var matchInputSource = true
    var screenMargin: CGFloat = 0
    private var lastKeyboardSource: String?
    private var inputSourceObserver: NSObjectProtocol?
    private var acceptsUpdates = false
    private var updateDownload: ReceiverUpdateDownload?
    var onUpdateReady: ((URL, ReceiverUpdateOffer) -> Void)?
    var onUpdateVersion: ((ReceiverUpdateVersion) -> Void)?
    private let modifiers = MacModifierState()
    private var roundTripMS: Int?
    var onStopped: (() -> Void)?
    var onConnected: (() -> Void)?
    var onVideoSample: ((RemoteView, CMSampleBuffer) -> Void)?
    let status: (String) -> Void

    init(receiverMode: ReceiverMode? = nil, status: @escaping (String) -> Void) {
        self.receiverMode = receiverMode
        self.status = status
    }

    func start(profile: ReceiverProfile) throws {
        let token = try LocalSetup.deviceToken()
        guard var greeting = strictHex(profile.invitation, count: 16) else {
            throw StudioError.message(L("받는 앱을 다시 만들어 주세요.", "Please create the viewer app again."))
        }
        greeting.append(token)
        let screen = NSScreen.screens.first ?? NSScreen.main
        let options = (profile.interactionV1 == true && receiverMode != nil) ? screen.flatMap {
            resolution.displayOptions(width: Int($0.frame.width.rounded()), height: Int($0.frame.height.rounded()))
        } : nil
        let large = options.map { $0.width > 1920 || $0.height > 1200 } ?? false
        let nativePixels = resolution == .native && options != nil ? screen.flatMap { screen in
            let pixels = screen.convertRectToBacking(NSRect(origin: .zero, size: screen.frame.size)).size
            return ReceiverNativePixels(width: Int(pixels.width.rounded()), height: Int(pixels.height.rounded()))
        } : nil
        if onUpdateVersion != nil {
            greeting.append(ReceiverUpdatePhase.checkOnlyGreeting)
        } else {
            greeting.append(large ? 1 : 0)
            if let options = options { greeting.append(options.bytes) }
        }
        let tunnel = RelayTunnel()
        self.tunnel = tunnel
        lastSeen = Date()
        try tunnel.start(profile, onEndpoint: { [weak self, weak tunnel] port in
            guard let self = self, let tunnel = tunnel, self.tunnel === tunnel else { return }
            do { try self.beginStream(profile: profile, port: port, greeting: greeting, nativePixels: nativePixels) }
            catch { self.stop(error.localizedDescription) }
        }, onFailure: { [weak self, weak tunnel] in
            guard let self = self, let tunnel = tunnel, self.tunnel === tunnel else { return }
            if self.connectionPath == .relay {
                self.stop(L("연결이 끊겼어요. 인터넷 연결을 확인하고, 보내는 맥이 보내기 중인지 살펴보세요.", "The connection dropped. Check your internet and make sure the host Mac is sharing."))
            }
        })
        status(onUpdateVersion == nil ? L("보내는 맥에 안전하게 연결하고 있어요…", "Connecting securely to the host Mac…") : L("새 버전을 확인하고 있어요…", "Checking for a new version…"))
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            let connected = self.sawScreens || (self.onUpdateVersion != nil && self.acceptsUpdates)
            let startupTimeout: TimeInterval = self.onUpdateVersion == nil ? 24 : 16
            if Date().timeIntervalSince(self.lastSeen) > (connected ? 12 : (self.waitingForApproval ? 82 : startupTimeout)) {
                self.stop(L("보내는 맥에서 응답이 없어요. 인터넷 연결을 확인하고, 보내는 맥이 보내기 중인지 살펴보세요.", "No response from the host Mac. Check your internet and make sure the host Mac is sharing."))
            } else if connected {
                self.sendHeartbeat()
                self.reportIfReady()
                self.sendKeyboardSourceIfChanged()
            }
        }
        self.timer = timer
        timer.resume()
    }

    func sendHeartbeat() {
        guard let wire = wire else { return }
        let sentAt = DispatchTime.now()
        let stamp = sentAt.uptimeNanoseconds / 1_000_000
        var data = Data()
        data.put(UInt32(truncatingIfNeeded: stamp >> 32))
        data.put(UInt32(truncatingIfNeeded: stamp))
        let sent = wire.send(.keepAlive, data: data)
        guard sawScreens else { return }
        guard sent else { setConnectionDelayed(true); return }

        heartbeatSentMS = stamp
        heartbeatWatch?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.heartbeatSentMS == stamp else { return }
            self.heartbeatWatch = nil
            self.setConnectionDelayed(true)
        }
        heartbeatWatch = work
        DispatchQueue.main.asyncAfter(deadline: sentAt + .milliseconds(Self.connectionDelayMS), execute: work)
    }

    private func setConnectionDelayed(_ delayed: Bool) {
        guard connectionDelayed != delayed else { return }
        connectionDelayed = delayed
        for view in views.values { view.setConnectionDelayed(delayed) }
    }

    private func sendKeyboardSourceIfChanged() {
        guard matchInputSource, receiverMode != nil,
              let display = views.values.first(where: { $0.display.macInputMatching == true })?.display.id,
              let id = MacInputSource.currentID(), MacInputSource.validID(id), id != lastKeyboardSource,
              let wire = wire else { return }
        var request = Input(action: .inputSource, display: display)
        request.keyboardInputSource = id
        if let data = try? JSONEncoder().encode(request), wire.send(.input, data: data) {
            lastKeyboardSource = id
        }
    }

    private func reportIfReady() {
        guard diagnosticsEnabled, reportAvailable else { return }
        let now = Date()
        let seconds = now.timeIntervalSince(lastReportAt)
        guard seconds >= 5 else { return }
        lastReportAt = now
        let samples = views.values.compactMap { $0.diagnostics() }.sorted { $0.id < $1.id }
        guard seconds <= 30 else { return }
        let tuning = ReceiverTuningStatus(session: diagnosticSession, resolution: resolution,
                                          allowed: remoteTuningAllowed && onResolutionRequested != nil)
        let report = ReceiverDiagnostics(seconds: Int(seconds.rounded()), displays: samples, roundTripMS: roundTripMS,
                                         systemShortcuts: receiverMode?.handlesSystemShortcuts,
                                         clientVersion: ReceiverUpdateVersion.current?.label, tuning: tuning,
                                         sentInputCount: sentInputCount, connectionPath: connectionPath)
        guard report.valid, let data = try? JSONEncoder().encode(report) else { return }
        wire?.send(.diagnostics, data: data)
    }

    private func beginStream(profile: ReceiverProfile, port: NWEndpoint.Port, greeting: Data,
                             nativePixels: ReceiverNativePixels?) throws {
        receive(on: Wire(try secureConnection(profile, port: port), queue: .main),
                greeting: greeting, profile: profile, nativePixels: nativePixels)
    }

    func receive(on wire: Wire, greeting: Data, profile: ReceiverProfile? = nil,
                 nativePixels: ReceiverNativePixels? = nil) {
        self.profile = profile
        diagnosticSession = UUID()
        let tryDirect = receiverMode != nil && onUpdateVersion == nil
        wire.onReady = { [weak wire] in
            guard let wire = wire else { return }
            var hello = greeting
            if tryDirect && hello.count > 48 && wire.supportsDirect {
                hello[48] |= 0x80
                if hello.count == 54, wire.supportsNativePixels, let nativePixels = nativePixels {
                    hello.append(nativePixels.bytes)
                }
            }
            wire.send(.hello, data: hello)
        }
        bind(wire)
        wire.start()
    }

    private func bind(_ wire: Wire) {
        self.wire = wire
        wire.onMessage = { [weak self, weak wire] kind, id, data in
            guard let self = self, let wire = wire, self.wire === wire else { return }
            if self.handoffRelay != nil {
                self.handoffRelay?.close()
                self.handoffRelay = nil
                self.tunnel?.close()
                self.tunnel = nil
            }
            self.receive(kind, id, data)
        }
        wire.onEnd = { [weak self, weak wire] reason in
            guard let self = self, let wire = wire, self.wire === wire else { return }
            if self.onUpdateVersion != nil {
                self.stop(L("새 버전을 확인하지 못했어요. 보내는 맥이 보내기 중인지 확인해 주세요.", "Couldn't check for a new version. Make sure the host Mac is sharing."))
            } else {
                self.stop(self.sawScreens ? reason : L("연결하지 못했어요. 인터넷 연결을 확인하고, 보내는 맥이 보내기 중인지 살펴보세요.", "Couldn't connect. Check your internet and make sure the host Mac is sharing."))
            }
        }
    }

    private struct DirectOffer: Decodable {
        let addresses: [String]
        let port: UInt16
        let ticket: String
    }

    private func tryDirect(_ data: Data) {
        guard let relay = wire, directTrials.isEmpty, connectionPath == .relay, !sawScreens else { return }
        guard let profile = profile, relay.supportsDirect, data.count <= 512,
              let offer = try? JSONDecoder().decode(DirectOffer.self, from: data),
              (1...4).contains(offer.addresses.count), offer.port != 0,
              let port = NWEndpoint.Port(rawValue: offer.port),
              let ticket = strictHex(offer.ticket, count: 32) else {
            relay.send(.directChoice, data: Data([0]))
            return
        }

        for address in offer.addresses {
            guard let ip = IPv4Address(address),
                  let socket = try? secureConnection(profile, host: .ipv4(ip), port: port) else { continue }
            let trial = Wire(socket, queue: .main)
            trial.onReady = { [weak trial] in trial?.send(.directTicket, data: ticket) }
            trial.onMessage = { [weak self, weak trial, weak relay] kind, id, data in
                guard let self = self, let trial = trial, let relay = relay,
                      self.wire === relay, self.directTrials.contains(where: { $0 === trial }),
                      kind == .directChoice, id == 0, data == Data([1]),
                      relay.send(.directChoice, data: Data([1])) else { return }
                self.finishDirectTrials(keeping: trial)
                self.connectionPath = .direct
                self.handoffRelay = relay
                self.bind(trial)
            }
            directTrials.append(trial)
        }
        if directTrials.isEmpty {
            relay.send(.directChoice, data: Data([0]))
            return
        }
        let timeout = DispatchWorkItem { [weak self, weak relay] in
            guard let self = self, let relay = relay, self.wire === relay else { return }
            self.finishDirectTrials()
            relay.send(.directChoice, data: Data([0]))
        }
        directTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(2), execute: timeout)
        for trial in directTrials { trial.start() }
    }

    private func finishDirectTrials(keeping selected: Wire? = nil) {
        directTimeout?.cancel()
        directTimeout = nil
        for trial in directTrials where trial !== selected { trial.close() }
        directTrials.removeAll()
    }

    func stop(_ reason: String = L("연결을 끝냈어요.", "Disconnected.")) {
        if suppressFinish { return }
        suppressFinish = true
        finishDirectTrials()
        handoffRelay?.close()
        handoffRelay = nil
        connectionPath = .relay
        profile = nil
        pointerWork?.cancel()
        pointerWork = nil
        pendingPointer = nil
        nextPointerTime = DispatchTime(uptimeNanoseconds: 0)
        if onUpdateVersion == nil { send(Input(action: .release)) }
        sentInputCount = 0
        let previous = wire
        wire = nil
        previous?.close()
        tunnel?.close()
        tunnel = nil
        timer?.cancel()
        timer = nil
        cancelInputReceipt()
        nextMotionReceipt = DispatchTime(uptimeNanoseconds: 0)
        heartbeatWatch?.cancel()
        heartbeatWatch = nil
        heartbeatSentMS = nil
        setConnectionDelayed(false)
        feedbackWork?.cancel()
        feedbackWork = nil
        recoveryWork?.cancel()
        recoveryWork = nil
        receipts.removeAll()
        for window in windows.values { window.close() }
        windows.removeAll()
        views.removeAll()
        modifiers.clear()
        if let observer = inputSourceObserver { NotificationCenter.default.removeObserver(observer) }
        inputSourceObserver = nil
        lastKeyboardSource = nil
        acceptsUpdates = false
        updateDownload = nil
        receiverMode?.display([])
        sawScreens = false
        reportAvailable = false
        roundTripMS = nil
        waitingForApproval = false
        suppressFinish = false
        status(reason)
        onStopped?()
    }

    private func receive(_ kind: Kind, _ id: UInt32, _ data: Data) {
        lastSeen = Date()
        switch kind {
        case .screens:
            guard onUpdateVersion == nil, !sawScreens, let displays = try? JSONDecoder().decode([DisplayInfo].self, from: data),
                  (1...8).contains(displays.count),
                  Set(displays.map { $0.id }).count == displays.count,
                  displays.allSatisfy({ (2...4096).contains($0.width) && (2...4096).contains($0.height) }) else {
                stop(L("보내는 맥의 화면 정보를 읽지 못했어요. 다시 연결해 주세요.", "Couldn't read the host Mac's screen info. Please connect again.")); return
            }
            sawScreens = true
            reportAvailable = displays.allSatisfy { $0.receiverDiagnostics == true }
            for display in displays where display.videoFeedback == true {
                let greeting = VideoFeedback(receivedBytes: 0, requestKeyframe: false)
                if wire?.send(.videoFeedback, screen: display.id, data: greeting.bytes) == true {
                    receipts[display.id] = VideoReceipt()
                }
            }
            lastReportAt = Date()
            onConnected?()
            if let host = displays.first(where: { $0.cursorShapes == true && $0.localCursor == true }) {
                send(Input(action: .cursorShapes, display: host.id))
            }
            if let receiverMode = receiverMode {
                let nativeCaps = matchInputSource && MacInputSource.usesSystemCapsSwitch && MacInputSource.koreanPair() != nil
                let remote = displays.map { display -> RemoteView in
                    let view = RemoteView(display: display, modifiers: modifiers)
                    view.kioskInput = true
                    view.screenMargin = display.nativePixels == true ? 0 : screenMargin
                    view.usesNativeCapsSwitch = nativeCaps && display.macInputMatching == true
                    bindInput(to: view)
                    views[display.id] = view
                    return view
                }
                receiverMode.display(remote)
                if onUpdateReady != nil, displays.contains(where: { $0.receiverUpdates == true }),
                   let version = ReceiverUpdateVersion.current {
                    acceptsUpdates = wire?.send(.receiverUpdate, screen: ReceiverUpdatePhase.version.rawValue,
                                                data: Data(version.label.utf8)) == true
                }
                if matchInputSource && displays.contains(where: { $0.macInputMatching == true }) {
                    inputSourceObserver = NotificationCenter.default.addObserver(
                        forName: NSTextInputContext.keyboardSelectionDidChangeNotification, object: nil, queue: .main
                    ) { [weak self] _ in self?.sendKeyboardSourceIfChanged() }
                    sendKeyboardSourceIfChanged()
                }
                let route = connectionPath == .direct ? L("바로 연결됐어요.", "Connected directly.") : L("연결 서버로 연결됐어요.", "Connected through the connection server.")
                let native = displays.first?.nativePixels == true
                status(resolution == .native ? route + (native ? L(" 원본 화질로 보여요.", " Showing full quality.") : L(" 화면은 ‘높음’으로 보내요.", " The screen is sent at High.")) : route)
                return
            }
            for (index, display) in displays.enumerated() {
                let window = RemoteWindow(display: display, order: index, modifiers: modifiers)
                bindInput(to: window.view)
                window.view.disconnect = { [weak self] in self?.stop() }
                window.onClose = { [weak self] id in
                    guard let self = self, !self.suppressFinish else { return }
                    self.windows[id] = nil
                    self.views[id] = nil
                    if self.windows.isEmpty { self.stop() }
                }
                windows[display.id] = window
                views[display.id] = window.view
                window.orderFront(nil)
            }
            if let first = displays.first { windows[first.id]?.makeKeyAndOrderFront(nil) }
            NSApp.activate(ignoringOtherApps: true)
            status(L("안전하게 연결됨 · 모니터 \(displays.count)개", "Connected securely · \(displays.count) display(s)"))
        case .directOffer: tryDirect(data)
        case .format: views[id]?.setFormat(data)
        case .video:
            let view = views[id]
            let sample = view?.frame(data)
            recordVideo(id: id, count: data.count, needsKeyframe: view?.needsVideoKeyframe == true)
            if let view = view, let sample = sample { onVideoSample?(view, sample) }
        case .keepAlive:
            if data.count == 8 {
                let first = data.number(at: 0)
                let second = data.number(at: 4)
                if first == Self.inputReceiptMarker {
                    for view in views.values { view.pointerFeedback.received(second) }
                } else {
                    let stamp = UInt64(first) << 32 | UInt64(second)
                    let now = DispatchTime.now().uptimeNanoseconds / 1_000_000
                    guard now >= stamp else { return }
                    let delay = now - stamp
                    if delay <= 10_000 { roundTripMS = Int(delay) }
                    if heartbeatSentMS == stamp {
                        heartbeatWatch?.cancel()
                        heartbeatWatch = nil
                        heartbeatSentMS = nil
                        setConnectionDelayed(delay >= UInt64(Self.connectionDelayMS))
                    }
                }
            }
        case .receiverUpdate: receiveUpdate(phase: id, data: data)
        case .receiverControl:
            guard sawScreens, diagnosticsEnabled, remoteTuningAllowed, updateDownload == nil, data.count <= 1024,
                  let request = try? JSONDecoder().decode(ReceiverResolutionRequest.self, from: data),
                  request.session == diagnosticSession, request.resolution != resolution else { return }
            onResolutionRequested?(request.resolution)
        case .cursor:
            guard sawScreens, let cursor = CursorShape(data)?.cursor else { return }
            for view in views.values { view.remoteCursor = cursor }
        case .failure: stop(String(decoding: data.prefix(1024), as: UTF8.self))
        case .pairing:
            let code = String(decoding: data, as: UTF8.self)
            guard !sawScreens, code.utf8.count == 6, code.utf8.allSatisfy({ (48...57).contains($0) }) else {
                stop(L("6자리 번호를 읽지 못했어요. 다시 연결해 주세요.", "Couldn't read the 6-digit code. Please connect again."))
                return
            }
            waitingForApproval = true
            status(L("6자리 번호 \(code) · 보내는 맥에 이 번호를 입력하고 ‘허용’을 누르세요.", "6-digit code \(code) · Enter this on the host Mac and click “Allow”."))
        default: stop(L("연결 데이터를 읽지 못했어요. 다시 연결해 주세요.", "Couldn't read the connection data. Please connect again."))
        }
    }

    private func recordVideo(id: UInt32, count: Int, needsKeyframe: Bool) {
        guard var receipt = receipts[id] else { return }
        receipt.bytes += UInt64(count)
        receipt.changed = true
        receipt.needsKeyframe = needsKeyframe
        if !needsKeyframe { receipt.requests = 0; receipt.lastRequestMS = nil }
        receipts[id] = receipt
        scheduleFeedback()
    }

    private func scheduleFeedback() {
        guard feedbackWork == nil, let wire = wire else { return }
        // Batch receipts briefly without waiting for another frame on a still desktop.
        let work = DispatchWorkItem { [weak self, weak wire] in
            guard let self = self, let wire = wire, self.wire === wire else { return }
            self.feedbackWork = nil
            self.sendFeedback(on: wire)
        }
        feedbackWork = work
        let delay = connectionPath == .direct ? 8 : 24
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delay), execute: work)
    }

    private func sendFeedback(on wire: Wire) {
        let now = DispatchTime.now().uptimeNanoseconds / 1_000_000
        var retryKeyframe = false
        for (id, var receipt) in receipts {
            let request = receipt.needsKeyframe && receipt.requests < 6 &&
                (receipt.lastRequestMS.map { now - $0 >= 500 } ?? true)
            if receipt.changed || request {
                let feedback = VideoFeedback(receivedBytes: receipt.bytes, requestKeyframe: request)
                if wire.send(.videoFeedback, screen: id, data: feedback.bytes) {
                    receipt.changed = false
                    if request { receipt.requests += 1; receipt.lastRequestMS = now }
                    receipts[id] = receipt
                }
            }
            retryKeyframe = retryKeyframe || receipt.changed || (receipt.needsKeyframe && receipt.requests < 6)
        }
        if retryKeyframe && recoveryWork == nil {
            // A later video frame sends its own receipt; this also works on a quiet screen.
            let work = DispatchWorkItem { [weak self, weak wire] in
                guard let self = self, let wire = wire, self.wire === wire else { return }
                self.recoveryWork = nil
                guard self.receipts.values.contains(where: { $0.changed || ($0.needsKeyframe && $0.requests < 6) }) else { return }
                self.scheduleFeedback()
            }
            recoveryWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(500), execute: work)
        }
    }

    func requestCheckedUpdate() -> Bool {
        guard onUpdateVersion != nil, acceptsUpdates else { return false }
        return wire?.send(.receiverUpdate, screen: ReceiverUpdatePhase.request.rawValue) == true
    }

    private func receiveUpdate(phase: UInt32, data: Data) {
        guard let phase = ReceiverUpdatePhase(rawValue: phase) else { return }
        if phase == .version, let onUpdateVersion = onUpdateVersion, !acceptsUpdates {
            guard let available = ReceiverUpdateVersion(String(decoding: data, as: UTF8.self)),
                  let current = ReceiverUpdateVersion.current,
                  wire?.send(.receiverUpdate, screen: ReceiverUpdatePhase.version.rawValue,
                             data: Data(current.label.utf8)) == true else {
                stop(L("새 버전을 확인하지 못했어요.", "Couldn't check for a new version."))
                return
            }
            acceptsUpdates = true
            onUpdateVersion(available)
            return
        }
        guard acceptsUpdates else { return }
        switch phase {
        case .offer:
            guard data.count <= 256, let current = ReceiverUpdateVersion.current,
                  let offer = try? JSONDecoder().decode(ReceiverUpdateOffer.self, from: data),
                  offer.isNewer(than: current) else { finishUpdate(success: false); return }
            updateDownload = ReceiverUpdateDownload(offer: offer)
            if onUpdateVersion != nil { status(L("새 버전(\(offer.version))을 받고 있어요…", "Downloading version \(offer.version)…")) }
        case .chunk:
            guard updateDownload != nil else { return }
            if updateDownload?.append(data) != true { finishUpdate(success: false) }
        case .complete:
            guard data.isEmpty, let download = updateDownload,
                  let file = try? download.offer.stage(download.payload) else { finishUpdate(success: false); return }
            finishUpdate(success: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.onUpdateReady?(file, download.offer)
            }
        default: break
        }
    }

    private func finishUpdate(success: Bool) {
        updateDownload = nil
        wire?.send(.receiverUpdate, screen: ReceiverUpdatePhase.result.rawValue, data: Data([success ? 1 : 0]))
        if !success && onUpdateVersion != nil { stop(L("새 버전 파일을 확인하지 못했어요. 다시 시도해 주세요.", "Couldn't verify the new version file. Please try again.")) }
    }

    private func bindInput(to view: RemoteView) {
        view.send = { [weak self] input in self?.send(input) }
        let display = view.display.id
        view.onGestureShortcut = { [weak self] in self?.requestInputReceipt(for: display) }
    }

    private func requestInputReceipt(for display: UInt32, immediately: Bool = false) {
        guard views[display] != nil else { return }
        receiptDisplays.insert(display)
        if immediately || DispatchTime.now() >= nextMotionReceipt {
            flushInputReceipt()
        } else if receiptWork == nil {
            // Keep a trailing probe for the last input in a scroll or gesture burst.
            let work = DispatchWorkItem { [weak self] in self?.flushInputReceipt() }
            receiptWork = work
            DispatchQueue.main.asyncAfter(deadline: nextMotionReceipt, execute: work)
        }
    }

    private func flushInputReceipt() {
        let feedback = receiptDisplays.compactMap { views[$0]?.pointerFeedback }
        cancelInputReceipt()
        guard let wire = wire, !feedback.isEmpty else { return }
        inputSequence &+= 1
        var probe = Data()
        probe.put(Self.inputReceiptMarker)
        probe.put(inputSequence)
        guard wire.send(.keepAlive, data: probe) else { return }
        nextMotionReceipt = .now() + Self.motionReceiptSpacing
        for indicator in feedback { indicator.wait(for: inputSequence) }
    }

    private func cancelInputReceipt() {
        receiptWork?.cancel()
        receiptWork = nil
        receiptDisplays.removeAll()
    }

    private func flushPointer() {
        pointerWork?.cancel()
        pointerWork = nil
        guard let pointer = pendingPointer else { return }
        pendingPointer = nil
        nextPointerTime = .now() + .milliseconds(33)
        sendInput(pointer, ordered: false)
    }

    private func send(_ input: Input) {
        // Idle motion only needs its latest position. Drags and other actions keep their order.
        if input.action == .move && input.pressure == nil {
            pendingPointer = input
            if DispatchTime.now() >= nextPointerTime {
                flushPointer()
            } else if pointerWork == nil {
                let work = DispatchWorkItem { [weak self] in self?.flushPointer() }
                pointerWork = work
                DispatchQueue.main.asyncAfter(deadline: nextPointerTime, execute: work)
            }
            return
        }
        flushPointer()
        sendInput(input, ordered: true)
    }

    private func sendInput(_ input: Input, ordered: Bool) {
        guard let wire = wire else { return }
        var packet = input
        if ordered { packet.sequence = sentInputCount + 1 }
        guard let data = try? JSONEncoder().encode(packet), wire.send(.input, data: data) else {
            if ordered { wire.close(L("입력 전송이 밀려서 연결을 끝냈어요.", "Input was delayed too long, so the connection was closed.")) }
            return
        }
        if ordered { sentInputCount += 1 }
        switch input.action {
        case .down:
            views[input.display]?.pointerFeedback.flash()
        case .up:
            requestInputReceipt(for: input.display, immediately: true)
        case .scroll, .gesture, .spacePrevious, .spaceNext, .missionControl, .appWindows,
             .zoomIn, .zoomOut, .launchApps, .showDesktop, .lookup, .notificationCenter,
             .pagePrevious, .pageNext, .rotateLeft, .rotateRight, .smartZoom:
            requestInputReceipt(for: input.display)
        case .release:
            cancelInputReceipt()
        default:
            break
        }
    }
}

private final class RemoteWindow: NSWindow, NSWindowDelegate {
    let view: RemoteView
    var onClose: ((UInt32) -> Void)?

    init(display: DisplayInfo, order: Int, modifiers: MacModifierState) {
        view = RemoteView(display: display, modifiers: modifiers)
        let screens = NSScreen.screens
        let screen = screens.isEmpty ? nil : screens[order % screens.count]
        let area = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let width = min(area.width * 0.85, CGFloat(display.width))
        let height = min(area.height * 0.84, width * CGFloat(display.height) / CGFloat(display.width))
        let shift = CGFloat(order % 5) * 12
        super.init(contentRect: NSRect(x: area.midX - width/2 + shift, y: area.midY - height/2 - shift,
                                      width: width, height: height),
                   styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        title = "\(ProductName.sender) · \(display.name)"
        collectionBehavior = [.fullScreenPrimary]
        acceptsMouseMovedEvents = true
        contentView = view
        delegate = self
        makeFirstResponder(view)
    }

    func windowDidResignKey(_ notification: Notification) { view.releaseInput() }
    func windowWillClose(_ notification: Notification) {
        view.releaseInput()
        onClose?(view.display.id)
    }

    override func sendEvent(_ event: NSEvent) {
        if isKeyWindow {
            switch event.type {
            case .keyDown, .keyUp, .flagsChanged:
                view.handleKey(event)
                return
            default: break
            }
        }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isKeyWindow, event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        view.handleKey(event)
        return true
    }
}

final class RemoteView: NSView {
    let display: DisplayInfo
    let image = AVSampleBufferDisplayLayer()
    fileprivate let pointerFeedback = PointerFeedback()
    var send: ((Input) -> Void)?
    fileprivate var onGestureShortcut: (() -> Void)?
    var disconnect: (() -> Void)?
    var kioskInput = false {
        didSet {
            allowedTouchTypes = kioskInput ? .indirect : []
            wantsRestingTouches = kioskInput
            needsLayout = true
        }
    }
    var screenMargin: CGFloat = 0 { didSet { needsLayout = true } }
    var usesNativeCapsSwitch = false
    private var swallowedShortcuts = Set<UInt16>()
    private var selectingScreenshot = false
    private var screenshotAnchor: NSPoint?
    private let screenshotOutline = CAShapeLayer()
    private var hidesLocalCursor: Bool { kioskInput && display.localCursor != true }
    /// The host's current cursor shape, shown instead of the local arrow over the remote screen.
    var remoteCursor: NSCursor? {
        didSet {
            guard let window = window else { return }
            if oldValue == nil { updateTrackingAreas() }
            window.invalidateCursorRects(for: self)
            if let cursor = remoteCursor, !hidesLocalCursor, !selectingScreenshot, isPointerOverRemoteScreen { cursor.set() }
        }
    }
    private static let hiddenCursor = NSCursor(
        image: NSImage(size: NSSize(width: 16, height: 16), flipped: false) { _ in true }, hotSpot: .zero)
    private var receivedFrames = 0
    private var submittedFrames = 0
    private var pinchEvents = 0
    private var multiTouchEvents = 0
    private var gestureShortcuts = 0
    private var nativeGestureEvents = 0
    private var nativeGestures = 0
    private enum PinchInput { case appKit, touchPositions }
    private var pinchInput: PinchInput?
    private var pinchAmount: CGFloat = 0
    private var pinch = TrackpadPinch()
    private var smartZoomWork: DispatchWorkItem?
    private var lastSystemGesture = -Double.infinity
    private var lastMultiFingerCommand: (time: TimeInterval, builtIn: Bool)?
    private var builtInGesture = TrackpadGestures()
    private var trackpad = TrackpadGestures()
    private var pointerButtons = Set<Int>()
    private var trackpadCommands: [String: Int] = [:]
    private var scrollEvents = 0
    private var naturalScrolling: Bool?
    private var format: CMVideoFormatDescription?
    private var tracking: NSTrackingArea?
    private let modifiers: MacModifierState
    private var localShortcut: UInt16?
    private var lastMotion = 0.0
    private var waitingForKeyFrame = true
    private var busyRenderFrames = 0
    var needsVideoKeyframe: Bool { format != nil && waitingForKeyFrame }
    private var scrollX: Double = 0
    private var scrollY: Double = 0

    init(display: DisplayInfo, modifiers: MacModifierState) {
        self.display = display
        self.modifiers = modifiers
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        image.videoGravity = .resize
        layer?.addSublayer(image)
        screenshotOutline.fillColor = NSColor.black.withAlphaComponent(0.18).cgColor
        screenshotOutline.strokeColor = NSColor.white.cgColor
        screenshotOutline.lineWidth = 1
        screenshotOutline.fillRule = .evenOdd
        layer?.addSublayer(screenshotOutline)
        layer?.addSublayer(pointerFeedback.layer)
    }

    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        image.frame = displayedRect
        if display.nativePixels == true, let window = window {
            image.contentsScale = window.backingScaleFactor
        }
        screenshotOutline.frame = bounds
        pointerFeedback.layout(in: bounds)
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking = tracking { removeTrackingArea(tracking) }
        var options: NSTrackingArea.Options = [.inVisibleRect, .mouseMoved, .mouseEnteredAndExited, .activeInActiveApp]
        if hidesLocalCursor || selectingScreenshot || remoteCursor != nil { options.insert(.cursorUpdate) }
        let next = NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil)
        addTrackingArea(next)
        tracking = next
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if selectingScreenshot { addCursorRect(bounds, cursor: .crosshair) }
        else if hidesLocalCursor { addCursorRect(bounds, cursor: Self.hiddenCursor) }
        else if let cursor = remoteCursor { addCursorRect(displayedRect, cursor: cursor) }
    }

    override func cursorUpdate(with event: NSEvent) {
        if selectingScreenshot { NSCursor.crosshair.set() }
        else if hidesLocalCursor { Self.hiddenCursor.set() }
        else if let cursor = remoteCursor, isPointerOverRemoteScreen { cursor.set() }
        else { super.cursorUpdate(with: event) }
    }

    func diagnostics() -> ReceiverDisplayDiagnostics? {
        let local = convertToBacking(bounds.size)
        defer { receivedFrames = 0; submittedFrames = 0 }
        guard local.width > 0, local.height > 0 else { return nil }
        return ReceiverDisplayDiagnostics(
            id: display.id, localWidth: Int(local.width.rounded()), localHeight: Int(local.height.rounded()),
            fillsScreen: abs(displayedRect.width - bounds.width) < 1 && abs(displayedRect.height - bounds.height) < 1,
            localCursorHidden: hidesLocalCursor, receivedFrames: receivedFrames,
            submittedFrames: submittedFrames, pinchEvents: pinchEvents, multiTouchEvents: multiTouchEvents,
            gestureShortcuts: gestureShortcuts, nativeGestureEvents: nativeGestureEvents, nativeGestures: nativeGestures,
            scrollEvents: scrollEvents, naturalScrolling: naturalScrolling,
            visibleWidth: max(1, Int(convertToBacking(displayedRect.size).width.rounded())),
            visibleHeight: max(1, Int(convertToBacking(displayedRect.size).height.rounded())),
            trackpadCommands: trackpadCommands.isEmpty ? nil : trackpadCommands)
    }

    func setFormat(_ data: Data) {
        guard data.count >= 14 else { return }
        let firstLength = Int(data.number(at: 0))
        guard (1...4000).contains(firstLength), 4 + firstLength + 8 < data.count else { return }
        let secondLength = Int(data.number(at: 4 + firstLength))
        guard (1...4000).contains(secondLength), 12 + firstLength + secondLength == data.count else { return }
        let nalSize = data.number(at: 8 + firstLength + secondLength)
        guard [1, 2, 4].contains(nalSize) else { return }
        var description: CMFormatDescription?
        let result = data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> OSStatus in
            let base = buffer.bindMemory(to: UInt8.self).baseAddress!
            let pointers = [base.advanced(by: 4), base.advanced(by: 8 + firstLength)]
            let sizes = [firstLength, secondLength]
            return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: 2, parameterSetPointers: pointers,
                parameterSetSizes: sizes, nalUnitHeaderLength: Int32(nalSize), formatDescriptionOut: &description)
        }
        if result == noErr {
            format = description
            needsLayout = true
            waitingForKeyFrame = true
            busyRenderFrames = 0
            image.flush()
        }
    }

    func frame(_ data: Data) -> CMSampleBuffer? {
        receivedFrames += 1
        guard data.count > 1, let format = format else { return nil }
        let sync = data.first == 1
        if image.isReadyForMoreMediaData { busyRenderFrames = 0 }
        else if !waitingForKeyFrame { busyRenderFrames += 1 }
        // A short burst can temporarily fill the renderer without breaking the H.264 chain.
        if image.status == .failed || image.requiresFlushToResumeDecoding || busyRenderFrames >= 3 {
            image.flush()
            waitingForKeyFrame = true
            busyRenderFrames = 0
        }
        guard sync || !waitingForKeyFrame else { return nil }
        let size = data.count - 1
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: size, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: size,
            flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block
        ) == noErr, let block = block else { return nil }
        let copy = data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            CMBlockBufferReplaceDataBytes(with: buffer.baseAddress!.advanced(by: 1),
                                         blockBuffer: block, offsetIntoDestination: 0, dataLength: size)
        }
        guard copy == noErr else { return nil }
        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sampleSize = size
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format,
                                        sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
                                        sampleBufferOut: &sample) == noErr, let sample = sample else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        waitingForKeyFrame = false
        image.enqueue(sample)
        submittedFrames += 1
        return sample
    }

    fileprivate func setConnectionDelayed(_ delayed: Bool) {
        if delayed { refreshFeedbackPosition() }
        pointerFeedback.setConnectionDelayed(delayed)
    }

    private func refreshFeedbackPosition() {
        guard let window = window else { return }
        guard !selectingScreenshot, NSApp.isActive, window.isVisible else {
            pointerFeedback.move(to: nil)
            return
        }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        pointerFeedback.move(to: displayedRect.contains(point) ? point : nil)
    }

    var isPointerOverRemoteScreen: Bool {
        guard !selectingScreenshot, let window = window, window.isVisible else { return false }
        return displayedRect.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    func releaseInput() {
        cancelBuiltInTrackpadGesture()
        pointerFeedback.clear()
        modifiers.clear()
        localShortcut = nil
        swallowedShortcuts.removeAll()
        endScreenshotSelection()
        pointerButtons.removeAll()
        scrollX = 0
        scrollY = 0
        resetTouchTracking()
        send?(Input(action: .release))
    }

    func handleKey(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.type == .keyUp && localShortcut == event.keyCode { localShortcut = nil; return }
        if !kioskInput && event.type == .keyDown && flags == [.control, .option] {
            switch event.keyCode {
            case 3: localShortcut = event.keyCode; window?.toggleFullScreen(nil); return
            case 12: localShortcut = event.keyCode; disconnect?(); return
            default: break
            }
        }
        let rawFlags = UInt64(event.modifierFlags.rawValue) & MacModifierKey.supportedFlags
        if event.keyCode == UInt16(kVK_CapsLock) {
            if usesNativeCapsSwitch { return }
            if display.koreanCaps == true {
                if modifiers.shouldSwitchLanguage(event) { send?(Input(action: .koreanCaps, display: display.id)) }
                return
            }
        }
        if display.macInputMatching == true {
            if event.type == .keyUp && swallowedShortcuts.remove(event.keyCode) != nil { return }
            if event.type == .keyDown {
                if swallowedShortcuts.contains(event.keyCode) { return }
                if selectingScreenshot && event.keyCode == UInt16(kVK_Escape) {
                    swallowedShortcuts.insert(event.keyCode)
                    endScreenshotSelection()
                    return
                }
                if let screenshot = Self.screenshotAction(key: event.keyCode, flags: flags,
                                                          compatibility: kioskInput && display.clipboardScreenshots == true) {
                    swallowedShortcuts.insert(event.keyCode)
                    if !event.isARepeat {
                        if display.clipboardScreenshots == true {
                            switch screenshot {
                            case .screenshotFull: copyEntireSenderScreen()
                            case .screenshotArea: selectSenderScreenshot()
                            default: DispatchQueue.main.async { [weak self] in self?.showScreenshotChoices() }
                            }
                        } else {
                            send?(Input(action: screenshot, display: display.id, flags: rawFlags))
                        }
                    }
                    return
                }
            }
        }
        let action: Input.Action
        var state = 0
        switch event.type {
        case .keyDown: action = .keyDown
        case .keyUp: action = .keyUp
        case .flagsChanged:
            guard let held = modifiers.update(key: event.keyCode, flags: event.modifierFlags) else { return }
            action = .flags
            state = held ? 1 : 0
        default: return
        }
        let keyboardType = event.cgEvent?.getIntegerValueField(.keyboardEventKeyboardType)
        var outgoingFlags = rawFlags
        if display.macInputMatching == true && action != .flags {
            outgoingFlags = modifiers.synchronize(flags: event.modifierFlags) { key, down, flags in
                var transition = Input(action: .flags, display: self.display.id, a: Int(key), b: down ? 1 : 0, flags: flags)
                transition.keyboardType = keyboardType
                self.send?(transition)
            }
        }
        var input = Input(action: action, display: display.id, a: Int(event.keyCode), b: state, flags: outgoingFlags)
        input.keyboardType = keyboardType
        if action == .keyDown && event.isARepeat { input.repeatKey = true }
        send?(input)
    }

    @objc private func copyEntireSenderScreen() {
        endScreenshotSelection()
        send?(Input(action: .screenshotFull, display: display.id))
    }

    @objc private func selectSenderScreenshot() {
        pointerFeedback.clear()
        endScreenshotSelection()
        resetTouchTracking()
        selectingScreenshot = true
        updateTrackingAreas()
        window?.invalidateCursorRects(for: self)
        NSCursor.crosshair.set()
    }

    private func showScreenshotChoices() {
        guard window?.isVisible == true else { return }
        let menu = NSMenu()
        let full = menu.addItem(withTitle: L("보내는 맥 전체 화면 복사", "Copy the host Mac's entire screen"), action: #selector(copyEntireSenderScreen), keyEquivalent: "")
        let area = menu.addItem(withTitle: L("영역을 골라 복사", "Copy a selected area"), action: #selector(selectSenderScreenshot), keyEquivalent: "")
        full.target = self
        area.target = self
        let rect = displayedRect
        menu.popUp(positioning: nil, at: NSPoint(x: rect.midX - 100, y: rect.maxY - 18), in: self)
    }

    private func endScreenshotSelection() {
        guard selectingScreenshot else { return }
        selectingScreenshot = false
        screenshotAnchor = nil
        screenshotOutline.path = nil
        window?.invalidateCursorRects(for: self)
        (remoteCursor ?? NSCursor.arrow).set()
    }

    private func screenshotPointer(_ action: Input.Action, _ point: NSPoint, _ button: Int) {
        guard button == 0 else { return }
        let area = displayedRect
        guard area.width > 0, area.height > 0 else { endScreenshotSelection(); return }
        let position = NSPoint(x: min(area.maxX, max(area.minX, point.x)),
                               y: min(area.maxY, max(area.minY, point.y)))
        switch action {
        case .down: screenshotAnchor = position
        case .move:
            guard let start = screenshotAnchor else { return }
            let selected = CGRect(x: min(start.x, position.x), y: min(start.y, position.y),
                                  width: abs(start.x - position.x), height: abs(start.y - position.y))
            let path = CGMutablePath()
            path.addRect(area)
            path.addRect(selected)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            screenshotOutline.path = path
            CATransaction.commit()
        case .up:
            let start = screenshotAnchor
            endScreenshotSelection()
            guard let start = start, abs(start.x - position.x) >= 2, abs(start.y - position.y) >= 2 else { return }
            var input = Input(action: .screenshotArea, display: display.id)
            input.screenshotRegion = ScreenshotRegion(first: Self.position(start, in: area),
                                                     last: Self.position(position, in: area))
            send?(input)
        default: break
        }
    }

    static func screenshotAction(key: UInt16, flags: NSEvent.ModifierFlags, compatibility: Bool = false) -> Input.Action? {
        let relevant = flags.intersection([.command, .shift, .control, .option])
        let systemChord = relevant.subtracting(.control) == [.command, .shift]
        // This chord reaches the app's local monitor when macOS owns the system screenshot keys.
        let localChord = compatibility && relevant == [.control, .option, .command]
        guard systemChord || localChord else { return nil }
        switch Int(key) {
        case kVK_ANSI_3: return .screenshotFull
        case kVK_ANSI_4: return .screenshotArea
        case kVK_ANSI_5: return .screenshotOptions
        default: return nil
        }
    }

    var displayedRect: NSRect {
        var size = NSSize(width: display.width, height: display.height)
        if let format = format {
            let presentation = CMVideoFormatDescriptionGetPresentationDimensions(
                format, usePixelAspectRatio: true, useCleanAperture: true)
            if presentation.width > 0 && presentation.height > 0 { size = presentation }
        }
        return Self.videoRect(in: bounds, videoSize: size, margin: screenMargin)
    }

    static func videoRect(in bounds: NSRect, videoSize: NSSize, margin: CGFloat = 0) -> NSRect {
        let available = bounds.insetBy(dx: bounds.width * margin, dy: bounds.height * margin)
        let scale = min(available.width / videoSize.width, available.height / videoSize.height)
        let width = min(available.width, videoSize.width * scale)
        let height = min(available.height, videoSize.height * scale)
        return NSRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height)
    }

    static func position(_ point: NSPoint, in video: NSRect) -> CGPoint {
        CGPoint(x: (point.x - video.minX) / video.width, y: (video.maxY - point.y) / video.height)
    }

    private func pointer(_ action: Input.Action, _ event: NSEvent, _ button: Int = 0, _ other: Int = 0,
                         gestureData: Data? = nil, scrollMotion: ScrollMotion? = nil) {
        let rect = displayedRect
        guard rect.width > 0, rect.height > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        if selectingScreenshot { screenshotPointer(action, point, button); return }
        let position = Self.position(point, in: rect)
        let x = position.x
        let y = position.y
        let inside = (0...1).contains(x) && (0...1).contains(y)
        pointerFeedback.move(to: inside ? point : nil)
        let phases = scrollMotion.map { _ in ScrollMotion.phases(for: event) }
        let endsScroll = phases.map { $0.0 == 4 || $0.0 == 8 || $0.1 == 3 } ?? false
        if action == .down {
            guard inside else { return }
            pointerButtons.insert(button)
            clearSmartZoom()
            if trackpad.isTracking { trackpad.cancel() }
            window?.makeFirstResponder(self)
        } else if action == .up {
            guard pointerButtons.remove(button) != nil else { return }
        } else if !inside && !endsScroll && (pointerButtons.isEmpty || action == .scroll || action == .gesture) {
            return
        }
        var input = Input(action: action, display: display.id, x: min(1, max(0, x)), y: min(1, max(0, y)),
                          a: button, b: other, flags: UInt64(event.modifierFlags.rawValue))
        if let motion = scrollMotion, let phases = phases {
            (input.scrollPhase, input.momentumPhase) = phases
            input.scrollMotion = motion
            scrollEvents += 1
            naturalScrolling = motion.invertedFromDevice
        } else if action == .down || action == .up || action == .move && event.type != .mouseMoved {
            input.pressure = Double(event.pressure)
        }
        input.gestureData = gestureData
        send?(input)
    }

    override func mouseEntered(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if !selectingScreenshot && displayedRect.contains(point) { pointerFeedback.move(to: point) }
    }

    override func mouseExited(with event: NSEvent) { pointerFeedback.move(to: nil) }

    override func mouseMoved(with event: NSEvent) {
        if event.timestamp - lastMotion > 1.0 / 120.0 { lastMotion = event.timestamp; pointer(.move, event) }
    }
    override func mouseDown(with event: NSEvent) { pointer(.down, event, 0, event.clickCount) }
    override func mouseUp(with event: NSEvent) { pointer(.up, event, 0, event.clickCount) }
    override func mouseDragged(with event: NSEvent) { pointer(.move, event) }
    override func rightMouseDown(with event: NSEvent) { pointer(.down, event, 1, event.clickCount) }
    override func rightMouseUp(with event: NSEvent) { pointer(.up, event, 1, event.clickCount) }
    override func rightMouseDragged(with event: NSEvent) { pointer(.move, event, 1) }
    override func otherMouseDown(with event: NSEvent) { pointer(.down, event, event.buttonNumber, event.clickCount) }
    override func otherMouseUp(with event: NSEvent) { pointer(.up, event, event.buttonNumber, event.clickCount) }
    override func otherMouseDragged(with event: NSEvent) { pointer(.move, event, event.buttonNumber) }
    override func scrollWheel(with event: NSEvent) {
        guard let motion = ScrollMotion(event) else { return }
        if abs(motion.horizontal) + abs(motion.vertical) > 0.5 {
            clearSmartZoom()
            trackpad.inhibitTap()
        }
        let multiplier = motion.continuous ? 1.0 : 12.0
        scrollX += motion.horizontal * multiplier
        scrollY += motion.vertical * multiplier
        let horizontal = Int(scrollX.rounded(.towardZero))
        let vertical = Int(scrollY.rounded(.towardZero))
        scrollX -= Double(horizontal)
        scrollY -= Double(vertical)
        if motion.horizontal != 0 || motion.vertical != 0 || !event.phase.isEmpty || !event.momentumPhase.isEmpty {
            pointer(.scroll, event, vertical, horizontal, scrollMotion: motion)
        }
    }

    @discardableResult
    private func gesture(_ event: NSEvent) -> Bool {
        guard isRemoteGesture(event.type) else { return false }
        nativeGestureEvents += 1
        guard let cg = event.cgEvent, let data = StudioCopyEventData(cg) as Data?,
              data.count <= 4096 else { return false }
        nativeGestures += 1
        pointer(.gesture, event, gestureData: data)
        return true
    }

    private func clearSmartZoom() {
        smartZoomWork?.cancel()
        smartZoomWork = nil
        trackpad.clearPairTap()
    }

    private func shortcut(_ key: Int, modifiers: NSEvent.ModifierFlags) {
        guard let send = send else { return }
        let flags = UInt64(modifiers.rawValue)
        send(Input(action: .keyDown, display: display.id, a: key, flags: flags))
        send(Input(action: .keyUp, display: display.id, a: key, flags: flags))
        onGestureShortcut?()
        gestureShortcuts += 1
    }

    private func gestureCommand(_ action: Input.Action) {
        refreshFeedbackPosition()
        let original = action == .spacePrevious || action == .spaceNext || action == .missionControl ||
            action == .appWindows || action == .zoomIn || action == .zoomOut
        if display.advancedTrackpad == true || (original && display.macInputMatching == true) ||
            (display.localCursor == true && (action == .spacePrevious || action == .spaceNext)) {
            guard let send = send else { return }
            send(Input(action: action, display: display.id))
            gestureShortcuts += 1
            trackpadCommands[action.rawValue, default: 0] += 1
            return
        }
        // Older senders accept the original physical keyboard messages.
        switch action {
        case .spacePrevious: shortcut(kVK_LeftArrow, modifiers: .control)
        case .spaceNext: shortcut(kVK_RightArrow, modifiers: .control)
        case .missionControl: shortcut(kVK_UpArrow, modifiers: .control)
        case .appWindows: shortcut(kVK_DownArrow, modifiers: .control)
        case .zoomIn: shortcut(kVK_ANSI_Equal, modifiers: [.command, .shift])
        case .zoomOut: shortcut(kVK_ANSI_Minus, modifiers: .command)
        default: break
        }
    }

    override func magnify(with event: NSEvent) {
        guard kioskInput else { gesture(event); return }
        guard pinchInput != .touchPositions, pointerButtons.isEmpty,
              !trackpad.hasSeveralFingers, !builtInGesture.isTracking else { return }
        pinchInput = .appKit
        trackpad.inhibitTap()
        pinchEvents += 1
        if event.phase == .began { pinchAmount = 0 }
        if event.phase == .cancelled { resetTouchTracking(); return }
        let step: CGFloat = 0.14
        if event.magnification.isFinite {
            pinchAmount += min(step * 2, max(-step * 2, event.magnification))
        }
        while abs(pinchAmount) >= step {
            gestureCommand(pinchAmount > 0 ? .zoomIn : .zoomOut)
            pinchAmount += pinchAmount > 0 ? -step : step
        }
        if event.phase == .ended { pinchAmount = 0 }
    }

    private func multiFingerCommand(_ action: Input.Action, at time: TimeInterval, builtIn: Bool) {
        // Both sources may recognize the same swipe. Suppress only the other
        // source, so two intentionally quick gestures on one source still work.
        if let previous = lastMultiFingerCommand, previous.builtIn != builtIn, abs(time - previous.time) < 0.35 {
            return
        }
        lastMultiFingerCommand = (time, builtIn)
        lastSystemGesture = time
        gestureCommand(action)
    }

    func interpretBuiltInTrackpad(_ positions: [CGPoint], at time: TimeInterval, dragging: Bool = false) {
        if selectingScreenshot || dragging || !pointerButtons.isEmpty || NSEvent.pressedMouseButtons != 0 ||
            positions.count > 4 {
            builtInGesture.cancel()
        }
        if (3...4).contains(positions.count) { multiTouchEvents += 1 }
        if let action = builtInGesture.update(positions, at: time, aspect: 0.65,
                                              allowLookup: display.advancedTrackpad == true) {
            multiFingerCommand(action, at: time, builtIn: true)
        }
    }

    func cancelBuiltInTrackpadGesture() {
        builtInGesture = TrackpadGestures()
        lastMultiFingerCommand = nil
    }

    private func trackTouches(_ event: NSEvent) {
        guard kioskInput else { return }
        let all = event.touches(matching: .touching, in: self)
        let active = all.filter { !$0.isResting }
        let touches = active.count == 3 && all.count == 4 ? all : active
        let device = touches.first?.deviceSize ?? .zero
        let aspect = device.width > 0 && device.height > 0 ? device.height / device.width : 0.65
        interpretTrackpad(touches.map(\.normalizedPosition), at: event.timestamp, aspect: aspect,
                          dragging: !pointerButtons.isEmpty || NSEvent.pressedMouseButtons != 0)
    }

    func interpretTrackpad(_ positions: [CGPoint], at time: TimeInterval, aspect: CGFloat, dragging: Bool = false) {
        if dragging { trackpad.cancel() }
        if (3...4).contains(positions.count) { multiTouchEvents += 1 }
        if let action = trackpad.update(positions, at: time, aspect: aspect, allowLookup: display.advancedTrackpad == true,
                                       allowEdge: display.notificationShortcut == true, allowSmartZoom: display.advancedTrackpad == true) {
            if action == .smartZoom {
                let work = DispatchWorkItem { [weak self] in
                    self?.smartZoomWork = nil
                    self?.gestureCommand(.smartZoom)
                }
                smartZoomWork?.cancel()
                smartZoomWork = work
                // AppKit may report a secondary click just after the touches lift.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.055, execute: work)
            } else {
                switch action {
                case .spacePrevious, .spaceNext, .missionControl, .appWindows, .lookup, .launchApps, .showDesktop:
                    multiFingerCommand(action, at: time, builtIn: false)
                default:
                    gestureCommand(action)
                }
            }
        }
        if positions.isEmpty {
            pinchInput = nil
            pinchAmount = 0
            pinch = TrackpadPinch()
        } else if positions.count == 2 && !trackpad.hasSeveralFingers && !trackpad.consumed &&
                    !builtInGesture.isTracking && pinchInput != .appKit {
            let scaled = positions.map { CGPoint(x: $0.x, y: $0.y * aspect) }
            if let action = pinch.update(scaled, allowRotation: display.advancedTrackpad == true) {
                pinchInput = .touchPositions
                trackpad.inhibitTap()
                if action == .zoomIn || action == .zoomOut { pinchEvents += 1 }
                gestureCommand(action)
            }
        } else {
            pinch = TrackpadPinch()
        }
    }

    private func resetTouchTracking() {
        pinchInput = nil
        pinchAmount = 0
        pinch = TrackpadPinch()
        clearSmartZoom()
        trackpad = TrackpadGestures()
    }

    override func touchesBegan(with event: NSEvent) { trackTouches(event) }
    override func touchesMoved(with event: NSEvent) { trackTouches(event) }
    override func touchesEnded(with event: NSEvent) { trackTouches(event) }
    override func touchesCancelled(with event: NSEvent) { resetTouchTracking() }
    override func rotate(with event: NSEvent) {
        if pinchInput != .touchPositions && gesture(event) {
            pinchInput = .appKit
            trackpad.inhibitTap()
        }
    }
    override func swipe(with event: NSEvent) {
        if kioskInput && display.advancedTrackpad == true && abs(event.deltaX) > abs(event.deltaY) {
            guard !trackpad.hasSeveralFingers && !trackpad.consumed && !builtInGesture.isTracking &&
                  event.timestamp - lastSystemGesture > 0.35 else { return }
            gestureCommand(event.deltaX > 0 ? .pagePrevious : .pageNext)
        } else {
            gesture(event)
        }
    }
    override func smartMagnify(with event: NSEvent) {
        clearSmartZoom()
        if !gesture(event) && display.advancedTrackpad == true { gestureCommand(.smartZoom) }
    }
    override func beginGesture(with event: NSEvent) { gesture(event) }
    override func endGesture(with event: NSEvent) { gesture(event) }
    override func pressureChange(with event: NSEvent) { gesture(event) }
}
