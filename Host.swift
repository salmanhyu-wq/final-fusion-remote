import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreImage
import IOKit.pwr_mgt
import Network
import ScreenCaptureKit
import VideoToolbox

@available(macOS 14.0, *)
func makeH264Encoder(width: Int, height: Int) throws -> VTCompressionSession {
    var session: VTCompressionSession?
    let specification = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true] as CFDictionary
    let result = VTCompressionSessionCreate(
        allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
        encoderSpecification: specification, imageBufferAttributes: nil, compressedDataAllocator: nil,
        outputCallback: nil, refcon: nil, compressionSessionOut: &session)
    guard result == noErr, let session = session else {
        throw StudioError.message(L("화면을 준비할 수 없어요 (\(result)). 앱을 다시 열어 보세요.", "Couldn't prepare the screen (\(result)). Reopen the app and try again."))
    }
    return session
}

@available(macOS 14.0, *)
final class StudioHost {
    struct Simulation {
        let displays: (Wire, ReceiverDisplayOptions?) throws -> [Capture]
        let onInput: (Input) -> Void
        var displayReady: (() -> Bool)? = nil
        var updatePayload: (() throws -> Data)? = nil
        var screenSaverActive: (() -> Bool)? = nil
        var nativeDisplay: ((Wire, ReceiverNativePixels) throws -> Capture)? = nil
        var nativeModeReady: (() -> Bool)? = nil
    }

    private let simulation: Simulation?
    private var listener: NWListener?
    private var peer: Wire?
    private var authorized = false
    private var updateOnly = false
    var receiverProfile: ReceiverProfile? {
        didSet { sendUpdateIfNeeded() }
    }
    private var streams: [Capture] = []
    var activeDisplayCount: Int { streams.count }
    private var timer: DispatchSourceTimer?
    private var lastSeen = Date()
    private var lastReport: Date?
    private var lastInputSequence: UInt64 = 0
    private var acceptedInputCount: UInt64 = 0
    private var receiverTuning: ReceiverTuningStatus?
    private var lastReceiverRequest: UUID?
    private var receiverVersion: ReceiverUpdateVersion?
    private var updateAttempted = false
    private var updateDownloadRequested = false
    private var updateDelivered = false
    private var updateTimer: DispatchSourceTimer?
    private var updatePending = false {
        didSet {
            if oldValue != updatePending { onUpdateActivity?(updatePending ? .busy : .idle) }
        }
    }
    var onUpdateActivity: ((OperationActivity) -> Void)?
    var onUpdateStatus: ((String) -> Void)?
    var onReceiverVersion: ((ReceiverUpdateVersion) -> Void)?

    private func updateStatus(_ message: String) { (onUpdateStatus ?? status)(message) }
    private var fittedDisplay: MatchedDisplay?
    private var nativeDisplay: SessionNativeDisplay?
    private var nativePixels: ReceiverNativePixels?
    private var nativeTrial: Capture?
    private var shareWithoutFitting = false
    private var resumeNativeAfterScreenSaver = false
    private var displayWake = IOPMAssertionID(0)
    private var displayActivity: NSObjectProtocol?
    private var streamMode = LocalSetup.streamMode()
    private let control = HostInput()
    private var cursorTimer: DispatchSourceTimer?
    private var lastCursor: Int?
    let code: Data
    let status: (String) -> Void
    var onReady: ((UInt16) -> Void)?
    var onFailure: ((String) -> Void)?

    init(simulation: Simulation? = nil, status: @escaping (String) -> Void) throws {
        self.simulation = simulation
        self.status = status
        code = try makeCode()
    }

    func start() throws {
        let parameters = tcpParameters()
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            switch state {
            case .ready:
                if let port = listener?.port { self?.onReady?(port.rawValue) }
            case let .failed(error):
                self?.onFailure?(error.localizedDescription)
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] conn in
            guard let self = self else { conn.cancel(); return }
            self.accept(conn)
        }
        self.listener = listener
        listener.start(queue: .main)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        if let wire = peer {
            clean(wire)
            wire.close()
        }
    }

    private func accept(_ conn: NWConnection) {
        guard peer == nil,
              case let .hostPort(.ipv4(address), _) = conn.endpoint,
              address == IPv4Address("127.0.0.1") else {
            conn.cancel()
            return
        }
        let wire = Wire(conn, queue: .main)
        peer = wire
        authorized = false
        updateAttempted = false
        updateDownloadRequested = false
        updateDelivered = false
        lastSeen = Date()
        wire.onMessage = { [weak self, weak wire] kind, screen, data in
            guard let self = self, let wire = wire, self.peer === wire else { return }
            self.receive(kind, screen: screen, data, wire: wire)
        }
        wire.onEnd = { [weak self, weak wire] reason in
            guard let self = self, let wire = wire else { return }
            let wasUpdating = self.updatePending
            self.clean(wire)
            guard self.listener != nil else { return }
            self.status(L("받는 기기 연결 대기 중 · \(reason)", "Waiting for a viewer · \(reason)"))
            if wasUpdating {
                self.updateStatus(L("받는 맥이 다시 연결되면 업데이트를 보내요.", "The update will be sent when the viewer reconnects."))
            }
        }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self, weak wire] in
            guard let self = self, let wire = wire else { return }
            let preparingScreen = self.authorized && !self.updateOnly && self.streams.isEmpty
            let timeout: TimeInterval = preparingScreen ? 20 : (self.authorized ? 10 : 5)
            if Date().timeIntervalSince(self.lastSeen) > timeout {
                wire.close(L("응답 시간이 지났어요.", "The connection timed out."))
            } else if self.authorized {
                if self.resumeNativeAfterScreenSaver, !self.streams.isEmpty, !self.isScreenSaverActive {
                    self.resumeNativeAfterScreenSaver = false
                    wire.close(L("화면 보호기가 끝났어요. 원본 화질로 다시 연결해요.", "The screen saver ended. Reconnecting at full quality."))
                    return
                }
                self.refreshStreamMode()
                self.sendReceiverControlIfReady()
            }
        }
        self.timer = timer
        timer.resume()
        wire.start()
    }

    private func clean(_ wire: Wire) {
        guard peer === wire else { return }
        authorized = false
        updateOnly = false
        lastReport = nil
        lastInputSequence = 0
        acceptedInputCount = 0
        receiverTuning = nil
        lastReceiverRequest = nil
        receiverVersion = nil
        stopUpdate()
        timer?.cancel()
        timer = nil
        cursorTimer?.cancel()
        cursorTimer = nil
        lastCursor = nil
        peer = nil
        control.endSession()
        let previous = streams
        streams = []
        for stream in previous { stream.stop() }
        nativeTrial?.stop()
        nativeTrial = nil
        nativePixels = nil
        shareWithoutFitting = false
        resumeNativeAfterScreenSaver = false
        restoreDisplay()
        if let activity = displayActivity {
            ProcessInfo.processInfo.endActivity(activity)
            displayActivity = nil
        }
        if displayWake != 0 {
            IOPMAssertionRelease(displayWake)
            displayWake = 0
        }
    }

    private func receive(_ kind: Kind, screen: UInt32, _ data: Data, wire: Wire) {
        if !authorized {
            let options = ReceiverDisplayOptions(Data(data.dropFirst(17).prefix(5)))
            let pixels = data.count == 26 ? ReceiverNativePixels(Data(data.suffix(4))) : nil
            let displayGreeting = options != nil && (data.count == 22 || (pixels != nil && options?.matchDisplay == true))
            let mode = data.dropFirst(16).first
            let checkOnly = mode == ReceiverUpdatePhase.checkOnlyGreeting && data.count == 17
            guard kind == .hello, data.count == 17 || displayGreeting,
                  matches(Data(data.prefix(16)), code), checkOnly || mode == 0 || mode == 1 else {
                wire.onMessage = nil
                wire.send(.failure, data: Data(L("접속 코드가 일치하지 않아요.", "The access code doesn't match.").utf8))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    wire.close(L("연결 확인에 실패했어요.", "Couldn't verify the connection."))
                }
                return
            }
            authorized = true
            lastSeen = Date()
            updateOnly = checkOnly
            if checkOnly {
                guard let version = ReceiverUpdateVersion.current,
                      wire.send(.receiverUpdate, screen: ReceiverUpdatePhase.version.rawValue,
                                data: Data(version.label.utf8)) else {
                    wire.close(L("버전을 확인하지 못했어요.", "Couldn't check the version."))
                    return
                }
                status(L("받는 기기가 새 버전을 확인하고 있어요.", "The viewer is checking for a new version."))
            } else {
                if simulation == nil { control.beginSession(macInputMatching: options?.localCursor == true) }
                status(L("받는 기기 확인 완료 · 화면 연결 중", "Viewer verified · connecting the screen"))
                nativePixels = pixels
                prepare(wire, retina: mode == 1, options: options)
            }
            return
        }
        switch kind {
        case .keepAlive:
            lastSeen = Date()
            wire.send(.keepAlive, data: data.count == 8 ? data : Data())
        case .diagnostics:
            receiveDiagnostics(data)
        case .videoFeedback:
            guard let feedback = VideoFeedback(data),
                  let capture = streams.first(where: { $0.info.id == screen && $0.info.videoFeedback == true }) else { return }
            capture.acknowledge(feedback)
        case .receiverUpdate:
            guard updateOnly || streams.contains(where: { $0.info.receiverUpdates == true }) else { return }
            switch ReceiverUpdatePhase(rawValue: screen) {
            case .version:
                guard receiverVersion == nil, data.count <= 23,
                      let version = ReceiverUpdateVersion(String(decoding: data, as: UTF8.self)) else { return }
                receiverVersion = version
                onReceiverVersion?(version)
                sendUpdateIfNeeded()
            case .request:
                guard updateOnly, data.isEmpty, !updatePending, !updateDelivered else { return }
                updateDownloadRequested = true
                updateAttempted = false
                sendUpdateIfNeeded()
            case .result:
                guard updatePending else { return }
                if data == Data([1]) {
                    updateDelivered = true
                    stopUpdate()
                    updateStatus(L("파일을 보냈어요. 받는 맥이 새 버전으로 연결되면 설치를 확인해요.",
                                   "Update sent. Installation is confirmed when the viewer reconnects with the new version."))
                } else if data == Data([0]) {
                    stopUpdate()
                    updateStatus(L("받는 맥이 파일을 확인하지 못했어요. 다시 연결하면 업데이트를 보내요.",
                                   "The viewer couldn't verify the file. The update will be sent when it reconnects."))
                }
            default: break
            }
        case .input:
            guard !updateOnly, data.count <= 8192, let input = try? JSONDecoder().decode(Input.self, from: data),
                  input.action == .release || streams.contains(where: { $0.info.id == input.display }) else { return }
            if let sequence = input.sequence {
                guard sequence > lastInputSequence else { return }
                lastInputSequence = sequence
                acceptedInputCount += 1
            }
            lastSeen = Date()
            if input.action == .cursorShapes {
                if streams.contains(where: { $0.info.cursorShapes == true }) { startCursorSync(wire) }
                return
            }
            if let simulation = simulation { simulation.onInput(input) }
            else { control.handle(input, capture: streams.first { $0.info.id == input.display }) }
        default: wire.close(L("잘못된 접속 메시지예요.", "Invalid connection message."))
        }
    }

    func sendReceiverUpdate() {
        guard !updatePending, !updateDelivered else { return }
        guard let receiverVersion, let version = ReceiverUpdateVersion.current else {
            updateStatus(L("받는 맥이 연결되면 버전을 확인하고 업데이트를 보내요.",
                           "When the viewer connects, its version is checked and the update is sent if needed."))
            return
        }
        guard receiverVersion < version else {
            onReceiverVersion?(receiverVersion)
            updateStatus(L("받는 맥이 이미 최신 버전이에요.", "The viewer is already up to date."))
            return
        }
        if updateOnly && !updateDownloadRequested {
            updateStatus(L("받는 맥에서 업데이트를 받기 시작하면 보내요.", "The update will be sent when the viewer starts the download."))
            return
        }
        updateAttempted = false
        sendUpdateIfNeeded()
    }

    private func sendUpdateIfNeeded() {
        guard !updateAttempted, !updatePending, !updateDelivered, !updateOnly || updateDownloadRequested,
              let profile = receiverProfile, let wire = peer, authorized,
              let receiverVersion, let version = ReceiverUpdateVersion.current, receiverVersion < version else { return }
        updateAttempted = true
        updatePending = true
        updateStatus(L("받는 기기에 보낼 업데이트를 준비하고 있어요…", "Preparing the update for the viewer…"))
        let makeTestPayload = simulation?.updatePayload
        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak wire] in
            let package = Result {
                if let makeTestPayload { return try makeTestPayload() }
                return try ReceiverUpdateOffer.package(profile)
            }
            DispatchQueue.main.async {
                guard let self = self, let wire = wire, self.peer === wire, self.updatePending else { return }
                switch package {
                case let .success(payload): self.transferUpdate(payload, version: version, wire: wire)
                case let .failure(error):
                    self.stopUpdate()
                    self.updateStatus(error.localizedDescription)
                }
            }
        }
    }

    private func transferUpdate(_ payload: Data, version: ReceiverUpdateVersion, wire: Wire) {
        // Keep the update from competing with screen frames on the same connection.
        for stream in streams { stream.pauseForUpdate(true) }
        let offer = ReceiverUpdateOffer(version: version, payload: payload)
        guard let header = try? JSONEncoder().encode(offer),
              wire.send(.receiverUpdate, screen: ReceiverUpdatePhase.offer.rawValue, data: header) else {
            stopUpdate()
            updateStatus(L("업데이트를 보내지 못했어요.", "Couldn't send the update."))
            return
        }
        updateStatus(L("받는 기기에 새 앱을 보내고 있어요…", "Sending the new app to the viewer…"))
        let timer = DispatchSource.makeTimerSource(queue: .main)
        var offset = 0
        var lastPercent = -1
        var lastProgress = Date()
        timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(50))
        timer.setEventHandler { [weak self, weak wire] in
            guard let self = self, let wire = wire, self.peer === wire else { return }
            let sentAll = offset > payload.count
            if Date().timeIntervalSince(lastProgress) > (sentAll ? 60 : 35) {
                self.stopUpdate()
                self.updateStatus(L("업데이트 전송이 늦어지고 있어요. 받는 맥이 다시 연결되면 보내요.",
                                        "The update timed out. It will be sent when the viewer reconnects."))
                return
            }
            guard !sentAll, wire.hasVideoRoom(maxPending: 64 * 1024) else { return }
            if offset < payload.count {
                let end = min(payload.count, offset + ReceiverUpdateOffer.chunkSize)
                if wire.send(.receiverUpdate, screen: ReceiverUpdatePhase.chunk.rawValue, data: payload.subdata(in: offset..<end)) {
                    offset = end
                    let percent = offset * 100 / payload.count
                    if percent != lastPercent {
                        lastPercent = percent
                        self.onUpdateActivity?(.progress(Double(percent) / 100))
                    }
                    lastProgress = Date()
                }
            } else if offset == payload.count, wire.send(.receiverUpdate, screen: ReceiverUpdatePhase.complete.rawValue) {
                offset += 1
                lastProgress = Date()
            }
        }
        updateTimer = timer
        timer.resume()
    }

    private func stopUpdate() {
        updateTimer?.cancel()
        updateTimer = nil
        updatePending = false
        for stream in streams { stream.pauseForUpdate(false) }
    }

    private func refreshStreamMode() {
        let mode = LocalSetup.streamMode()
        guard mode != streamMode else { return }
        streamMode = mode
        for stream in streams { stream.adjust(mode: mode) }
    }

    private func sendReceiverControlIfReady() {
        let now = Date()
        guard let wire = peer, !updateOnly, !updatePending, !streams.isEmpty,
              let reportTime = lastReport, (0...15).contains(now.timeIntervalSince(reportTime)),
              let tuning = receiverTuning, tuning.allowed,
              let request = LocalSetup.receiverResolutionRequest(), request.id != lastReceiverRequest,
              request.canSend(to: tuning, now: now),
              let data = try? JSONEncoder().encode(request),
              wire.send(.receiverControl, data: data) else { return }
        lastReceiverRequest = request.id
    }

    private func receiveDiagnostics(_ data: Data) {
        let now = Date()
        guard lastReport.map({ now.timeIntervalSince($0) >= 3 }) ?? true,
              data.count <= 8192,
              let report = try? JSONDecoder().decode(ReceiverDiagnostics.self, from: data), report.valid,
              report.displays.allSatisfy({ sample in streams.contains { $0.info.id == sample.id } }) else { return }
        lastReport = now
        receiverTuning = report.tuning
        refreshStreamMode()
        for sample in report.displays {
            streams.first { $0.info.id == sample.id }?.adjust(
                mode: streamMode, sample: sample, roundTripMS: report.roundTripMS,
                directHigh: report.connectionPath == .direct &&
                    (report.tuning?.resolution == .high || report.tuning?.resolution == .native))
        }
        let senderStreams = streams.map { $0.diagnostics() }
        let snapshot = ReceiverDiagnosticsSnapshot(
            receivedAt: now, mode: streamMode,
            reducedDisplays: senderStreams.filter(\.reduced).map(\.id),
            senderDisplays: streams.map(\.info), receiver: report, keyboardLayout: control.keyboardLayoutResult,
            receiverAppVersion: report.clientVersion ?? receiverVersion?.label, senderStreams: senderStreams,
            screenshotCopied: control.screenshotCopied,
            acceptedInputCount: report.sentInputCount.map { _ in acceptedInputCount })
        try? LocalSetup.saveReport(snapshot)
        sendReceiverControlIfReady()
    }

    private var hasAwakeDisplay: Bool {
        if let simulation = simulation { return simulation.displayReady?() ?? true }
        var displays = [CGDirectDisplayID](repeating: 0, count: 8)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(UInt32(displays.count), &displays, &count) == .success else { return false }
        return displays.prefix(Int(count)).contains { CGDisplayIsAsleep($0) == 0 }
    }

    private var isScreenSaverActive: Bool {
        if let simulation { return simulation.screenSaverActive?() ?? false }
        let bounds = CGDisplayBounds(CGMainDisplayID())
        guard !bounds.isEmpty,
              let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else { return false }
        let saverLevel = Int(CGWindowLevelForKey(.screenSaverWindow))
        return windows.contains { window in
            guard let layer = window[kCGWindowLayer as String] as? Int, layer >= saverLevel,
                  let owner = window[kCGWindowOwnerName as String] as? String,
                  let rect = window[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: rect as CFDictionary) else { return false }
            // Wallpaper processes can also have ordinary desktop windows, so require a full-screen overlay.
            let name = owner.lowercased()
            guard name.contains("screensaver") || name.hasPrefix("wallpaper") else { return false }
            let covered = bounds.intersection(frame)
            return covered.width >= bounds.width * 0.9 && covered.height >= bounds.height * 0.9
        }
    }

    private func prepare(_ wire: Wire, retina: Bool, options: ReceiverDisplayOptions?) {
        if simulation == nil {
            let displayAsleep = !hasAwakeDisplay
            if displayAsleep {
                status(L("이 맥의 화면을 깨우고 있어요…", "Waking this Mac's display…"))
            }
            if displayAsleep || isScreenSaverActive {
                _ = IOPMAssertionDeclareUserActivity("Studio Remote screen session" as CFString,
                                                    kIOPMUserActiveRemote, &displayWake)
            }
            displayActivity = ProcessInfo.processInfo.beginActivity(options: .idleDisplaySleepDisabled,
                                                                    reason: "Studio Remote screen session")
        }
        waitForDisplay(wire, retina: retina, options: options, retries: 14)
    }

    private func waitForDisplay(_ wire: Wire, retina: Bool, options: ReceiverDisplayOptions?, retries: Int) {
        guard peer === wire else { return }
        let displayAwake = hasAwakeDisplay
        let screenSaver = displayAwake && isScreenSaverActive
        if retries > 0 && (!displayAwake || screenSaver) {
            if screenSaver {
                status(L("보내는 맥의 화면 보호기가 끝나길 기다려요…", "Waiting for the host Mac's screen saver to end…"))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self, weak wire] in
                guard let self = self, let wire = wire else { return }
                self.waitForDisplay(wire, retina: retina, options: options, retries: retries - 1)
            }
            return
        }
        guard displayAwake else {
            failScreenStartup(L("이 맥의 화면을 깨우지 못했어요. 모니터 연결과 전원을 확인하세요.", "Couldn't wake this Mac's display. Check the monitor cable and power."), wire: wire)
            return
        }
        if screenSaver {
            // Keep remote input available on unattended Macs. Re-negotiate full quality once the saver is gone.
            shareWithoutFitting = true
            resumeNativeAfterScreenSaver = resumeNativeAfterScreenSaver || nativePixels != nil
            nativePixels = nil
        }
        if let simulation = simulation {
            do {
                if let pixels = nativePixels, let options, let makeDisplay = simulation.nativeDisplay {
                    try startNativeCapture([makeDisplay(wire, pixels)], wire: wire, retina: retina, options: options)
                } else {
                    try publish(simulation.displays(wire, options), to: wire)
                }
            } catch { failScreenStartup(error.localizedDescription, wire: wire) }
            return
        }
        if !shareWithoutFitting, let options = options, options.matchDisplay {
            if let pixels = nativePixels {
                fittedDisplay = MatchedDisplay.apply(options, retina: true, nativePixels: pixels)
                if fittedDisplay == nil, let display = SessionNativeDisplay(pixels) {
                    nativeDisplay = display
                    prepareNativeMirror(wire, display: display, retina: retina, options: options, retries: 4)
                    return
                }
                if fittedDisplay == nil { nativePixels = nil }
            }
            if nativePixels == nil { fittedDisplay = MatchedDisplay.apply(options, retina: retina) }
        }
        let settling: TimeInterval = fittedDisplay?.original == nil ? 0 : 0.25
        DispatchQueue.main.asyncAfter(deadline: .now() + settling) { [weak self, weak wire] in
            guard let self = self, let wire = wire, self.peer === wire else { return }
            self.prepareDisplays(wire, retina: retina, options: options, retries: 4)
        }
    }

    private func prepareNativeMirror(_ wire: Wire, display: SessionNativeDisplay, retina: Bool,
                                     options: ReceiverDisplayOptions, retries: Int) {
        // The virtual display exists before WindowServer publishes its usable modes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self, weak wire, weak display] in
            guard let self = self, let wire = wire, let display = display,
                  self.peer === wire, self.nativeDisplay === display else { return }
            if display.activate() {
                // Let WindowServer commit the new primary display before asking for capture content.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self, weak wire] in
                    guard let self, let wire, self.peer === wire else { return }
                    self.prepareDisplays(wire, retina: retina, options: options, retries: 4)
                }
            } else if retries > 0 {
                self.prepareNativeMirror(wire, display: display, retina: retina, options: options, retries: retries - 1)
            } else {
                self.fallbackFromNative(wire, retina: retina, options: options)
            }
        }
    }

    private func prepareDisplays(_ wire: Wire, retina: Bool, options: ReceiverDisplayOptions?, retries: Int) {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self, weak wire] content, error in
            DispatchQueue.main.async {
                guard let self = self, let wire = wire, self.peer === wire else { return }
                if !self.shareWithoutFitting && self.isScreenSaverActive {
                    self.restoreDisplay()
                    self.waitForDisplay(wire, retina: retina, options: options, retries: 8)
                    return
                }
                let main = self.nativeDisplay?.id ?? CGMainDisplayID()
                let source = content?.displays.first(where: { $0.displayID == main })
                let bounds = CGDisplayBounds(main)
                let sourceReady = source.map { CGFloat($0.width) == bounds.width && CGFloat($0.height) == bounds.height } ?? false
                let nativeReady = self.nativePixels.map { pixels in
                    guard sourceReady, self.nativeModeIsReady, let source else { return false }
                    if self.nativeDisplay?.isStandalone == true {
                        // In headless mode Quartz may omit the current display mode. Check the real capture scale.
                        let filter = SCContentFilter(display: source, excludingApplications: [], exceptingWindows: [])
                        let scale = CGFloat(filter.pointPixelScale)
                        let width = Int((filter.contentRect.width * scale).rounded())
                        let height = Int((filter.contentRect.height * scale).rounded())
                        return pixels.fitsSource(width: width, height: height)
                    }
                    return true
                } ?? true
                let modeSettling = self.fittedDisplay.map { fit in
                    !sourceReady || !fit.isApplied || fit.id != main
                } ?? false
                if retries > 0, (content?.displays.isEmpty != false || modeSettling || !nativeReady) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self, weak wire] in
                        guard let self = self, let wire = wire, self.peer === wire else { return }
                        self.prepareDisplays(wire, retina: retina, options: options, retries: retries - 1)
                    }
                    return
                }
                if !nativeReady {
                    self.fallbackFromNative(wire, retina: retina, options: options)
                    return
                }
                if modeSettling {
                    self.restoreDisplay()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self, weak wire] in
                        guard let self, let wire, self.peer === wire else { return }
                        self.prepareDisplays(wire, retina: retina, options: options, retries: 4)
                    }
                    return
                }
                do {
                    guard let content = content else {
                        throw error ?? StudioError.message(L("공유할 화면을 찾을 수 없어요.", "Couldn't find a screen to share."))
                    }
                    let primary = content.displays.filter { $0.displayID == main }
                    // The primary view needs the full receiving screen to stay pixel-for-pixel.
                    let ordered = self.nativePixels != nil ? primary :
                        primary + content.displays.filter { $0.displayID != main }
                    let captures = try ordered.prefix(8).enumerated().map { index, display in
                        try Capture(display: display, index: index, retina: retina, wire: wire,
                                    interactive: options?.localCursor == true, koreanCaps: self.control.supportsKoreanCaps,
                                    followsReceiver: self.fittedDisplay?.id == display.displayID ||
                                        self.nativeDisplay?.id == display.displayID,
                                    nativePixels: display.displayID == main ? self.nativePixels : nil)
                    }
                    if captures.first?.info.nativePixels == true {
                        self.startNativeCapture(captures, wire: wire, retina: retina, options: options)
                    } else {
                        try self.publish(captures, to: wire)
                    }
                } catch {
                    if self.nativePixels != nil {
                        self.fallbackFromNative(wire, retina: retina, options: options)
                    } else {
                        self.failScreenStartup(error.localizedDescription, wire: wire)
                    }
                }
            }
        }
    }

    private var nativeModeIsReady: Bool {
        if let simulation { return simulation.nativeModeReady?() ?? true }
        guard let pixels = nativePixels else { return false }
        let main = CGMainDisplayID()
        guard (nativeDisplay?.id ?? fittedDisplay?.id) == main, CGDisplayIsActive(main) != 0 else { return false }
        if let nativeDisplay {
            if nativeDisplay.isStandalone { return nativeDisplay.hasExpectedLogicalSize }
            guard nativeDisplay.isMirrored else { return false }
        }
        guard let mode = CGDisplayCopyDisplayMode(main) else { return false }
        return pixels.fitsSource(width: mode.pixelWidth, height: mode.pixelHeight)
    }

    private func restoreDisplay() {
        fittedDisplay?.restore()
        fittedDisplay = nil
        nativeDisplay?.restore()
        nativeDisplay = nil
    }

    private func fallbackFromNative(_ wire: Wire, retina: Bool, options: ReceiverDisplayOptions?) {
        if nativePixels != nil && isScreenSaverActive { resumeNativeAfterScreenSaver = true }
        nativePixels = nil
        restoreDisplay()
        status(L("원본 화질 화면을 준비하지 못해 ‘높음’으로 연결해요.", "Couldn't prepare full quality, so connecting at High."))
        // Wait for the original display to leave the mirror set before fitting it again.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self, weak wire] in
            guard let self = self, let wire = wire else { return }
            self.waitForDisplay(wire, retina: retina, options: options, retries: 8)
        }
    }

    private func failScreenStartup(_ reason: String, wire: Wire) {
        let message = L("화면 시작 실패 · ", "Screen start failed · ") + reason
        status(message)
        wire.onMessage = nil
        let sent = wire.send(.failure, data: Data(message.utf8.prefix(1024)))
        DispatchQueue.main.asyncAfter(deadline: .now() + (sent ? 0.5 : 0)) {
            wire.close(message)
        }
    }

    private func startNativeCapture(_ captures: [Capture], wire: Wire, retina: Bool, options: ReceiverDisplayOptions?) {
        guard let primary = captures.first else { return }
        nativeTrial = primary
        primary.pauseForUpdate(true)
        primary.start { [weak self, weak wire] error in
            DispatchQueue.main.async {
                guard let self = self, let wire = wire, self.peer === wire, self.nativeTrial === primary else {
                    primary.stop()
                    return
                }
                if error != nil {
                    self.nativeTrial = nil
                    primary.stop()
                    self.fallbackFromNative(wire, retina: retina, options: options)
                    return
                }
                self.confirmNativeFrame(captures, wire: wire, retina: retina, options: options, retries: 20)
            }
        }
    }

    private func confirmNativeFrame(_ captures: [Capture], wire: Wire, retina: Bool,
                                    options: ReceiverDisplayOptions?, retries: Int) {
        guard peer === wire, let primary = captures.first, nativeTrial === primary else { return }
        let ready = primary.hasStableNativeFrame && nativeModeIsReady && !isScreenSaverActive
        if !ready && retries > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self, weak wire] in
                guard let self = self, let wire = wire else { return }
                self.confirmNativeFrame(captures, wire: wire, retina: retina, options: options, retries: retries - 1)
            }
            return
        }
        nativeTrial = nil
        if ready, (try? publish(captures, to: wire, firstStarted: true)) != nil {
            primary.pauseForUpdate(false)
        } else {
            primary.stop()
            fallbackFromNative(wire, retina: retina, options: options)
        }
    }

    private func publish(_ captures: [Capture], to wire: Wire, firstStarted: Bool = false) throws {
        guard !captures.isEmpty else { throw StudioError.message(L("공유할 화면이 없어요.", "There's no screen to share.")) }
        guard wire.send(.screens, data: try JSONEncoder().encode(captures.map(\.info))) else {
            throw StudioError.message(L("화면 목록을 보낼 수 없어요.", "Couldn't send the screen list."))
        }
        lastSeen = Date()
        streams = captures
        streamMode = LocalSetup.streamMode()
        for capture in captures { capture.adjust(mode: streamMode) }
        startCapture(at: firstStarted ? 1 : 0, wire: wire)
    }

    /// Follows the system cursor (arrow, I-beam, pointing hand, resize…) so the receiver can show the same shape.
    private func startCursorSync(_ wire: Wire) {
        guard cursorTimer == nil, peer === wire else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(80), leeway: .milliseconds(20))
        timer.setEventHandler { [weak self, weak wire] in
            guard let self = self, let wire = wire, self.peer === wire else { return }
            self.sendCursorIfChanged(wire)
        }
        cursorTimer = timer
        timer.resume()
    }

    private func sendCursorIfChanged(_ wire: Wire) {
        guard let cursor = NSCursor.currentSystem,
              let (bitmap, fingerprint) = CursorShape.render(cursor, scale: 2), fingerprint != lastCursor,
              let shape = CursorShape.encode(cursor, rendered: bitmap) else { return }
        if wire.send(.cursor, data: shape.bytes) { lastCursor = fingerprint }
    }

    private func startCapture(at index: Int, wire: Wire) {
        guard peer === wire else { return }
        guard index < streams.count else {
            status(L("원격 연결 중 · 모니터 \(streams.count)개", "Connected remotely · \(streams.count) display(s)"))
            return
        }
        let capture = streams[index]
        capture.start { [weak self, weak wire, weak capture] error in
            DispatchQueue.main.async {
                guard let self = self, let wire = wire, self.peer === wire else {
                    capture?.stop()
                    return
                }
                if let error = error { self.failScreenStartup(error.localizedDescription, wire: wire) }
                else { self.startCapture(at: index + 1, wire: wire) }
            }
        }
    }
}

@available(macOS 14.0, *)
final class Capture: NSObject, SCStreamOutput, SCStreamDelegate {
    let info: DisplayInfo
    private let wire: Wire
    private let queue = DispatchQueue(label: "studio-remote.capture", qos: .userInteractive)
    private var stream: SCStream?
    private var screenFilter: SCContentFilter?
    private var active = false
    private var encoder: VTCompressionSession?
    private var sentFormat = false
    private var needKeyframe = true
    private var encoding = false
    private let fps: Int
    private let bitrate: Int
    private let interactive: Bool
    private var directHigh = false
    private var tuning = StreamTuning()

    private var targetBitRate: Int {
        guard tuning.load == .full else { return tuning.load.bitRate(bitrate) }
        if info.nativePixels == true { return min(22_000_000, max(bitrate, info.width * info.height * 4)) }
        return directHigh && interactive ? max(8_500_000, bitrate) : bitrate
    }
    private var delivery = VideoSendWindow()
    private var latestPixels: CVPixelBuffer?
    private var nativeFrameSince: DispatchTime?
    private var pendingFrame = false
    private var pausedForUpdate = false
    private var retry: DispatchWorkItem?
    private var refreshRequested = false
    private var lastRefreshMS: UInt64?
    private var lastNetworkCheckMS: UInt64?
    private var videoQueueDelayMS: Int?
    private var captured = 0
    private var creditBlocked = 0
    private var lastEncodedAt: UInt64 = 0
    private var encodeMS: Double?
    var isIdle: Bool { queue.sync { !active && encoder == nil } }

    var hasStableNativeFrame: Bool {
        queue.sync {
            guard let nativeFrameSince else { return false }
            return DispatchTime.now() >= nativeFrameSince + .milliseconds(300)
        }
    }

    convenience init(display: SCDisplay, index: Int, retina: Bool, wire: Wire,
         interactive: Bool, koreanCaps: Bool, followsReceiver: Bool,
         nativePixels: ReceiverNativePixels? = nil) throws {
        // The viewer can open and use the host's own settings window.
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let logical = CGDisplayBounds(display.displayID).size
        guard logical.width >= 2, logical.height >= 2 else { throw StudioError.message(L("화면 크기를 읽지 못했어요.", "Couldn't read the screen size.")) }
        let source = filter.contentRect.isEmpty ? logical : filter.contentRect.size
        let nativeScale = max(1, CGFloat(filter.pointPixelScale))
        let size = nativePixels?.size ??
            CaptureGeometry.outputSize(logical: logical, source: source, nativeScale: nativeScale, retina: retina)
        let width = Int(size.width), height = Int(size.height)
        let info = DisplayInfo(id: display.displayID, name: L("모니터 \(index + 1)", "Display \(index + 1)"), width: width, height: height,
                           receiverDiagnostics: true, localCursor: interactive ? true : nil,
                           followsReceiver: followsReceiver ? true : nil, macInputMatching: interactive ? true : nil,
                           receiverUpdates: interactive ? true : nil, koreanCaps: koreanCaps ? true : nil,
                           logicalWidth: Int(logical.width), logicalHeight: Int(logical.height),
                           advancedTrackpad: interactive ? true : nil,
                           notificationShortcut: interactive && ShortcutBinding.current(.notificationCenter) != nil ? true : nil,
                           videoFeedback: interactive ? true : nil, clipboardScreenshots: interactive ? true : nil,
                           nativePixels: nativePixels == nil ? nil : true,
                           cursorShapes: interactive ? true : nil)
        try self.init(info: info, retina: retina || nativePixels != nil, wire: wire, interactive: interactive)

        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: Int32(fps))
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        // One surface can be encoding while the newest replacement is retained.
        config.queueDepth = 4
        config.showsCursor = !interactive
        config.capturesAudio = false
        if #available(macOS 15.0, *) { config.captureMicrophone = false }
        if nativePixels != nil { config.captureResolution = .best }
        // The default rectangles capture every edge and fill the configured output surface.
        config.preservesAspectRatio = true
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        self.stream = stream
        self.screenFilter = filter
    }

    func screenshot(_ region: ScreenshotRegion?, completion: @escaping (CGImage?) -> Void) {
        func finish(_ image: CGImage?) {
            guard let image = image, let region = region else { completion(image); return }
            let size = CGSize(width: image.width, height: image.height)
            completion(region.pixels(in: size).flatMap { image.cropping(to: $0) })
        }

        guard let filter = screenFilter else { screenshotFromStream(finish); return }
        let config = SCStreamConfiguration()
        let size = filter.contentRect.size
        let scale = max(1, CGFloat(filter.pointPixelScale))
        config.width = max(2, Int(size.width * scale))
        config.height = max(2, Int(size.height * scale))
        config.showsCursor = false
        SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { [weak self] image, _ in
            if let image = image { finish(image) }
            else if let self = self { self.screenshotFromStream(finish) }
            else { finish(nil) }
        }
    }

    private func screenshotFromStream(_ completion: @escaping (CGImage?) -> Void) {
        queue.async { [weak self] in
            guard let pixels = self?.latestPixels else { completion(nil); return }
            DispatchQueue.global(qos: .userInitiated).async {
                let image = CIImage(cvPixelBuffer: pixels)
                completion(CIContext().createCGImage(image, from: image.extent))
            }
        }
    }

    init(info: DisplayInfo, retina: Bool, wire: Wire, interactive: Bool) throws {
        self.info = info
        fps = retina && info.width * info.height > 1920 * 1200 ? 30 : 60
        if info.nativePixels == true {
            bitrate = min(20_000_000, max(10_000_000, info.width * info.height * 3))
        } else {
            bitrate = interactive ? (retina ? 10_000_000 : 6_000_000) : (retina ? 18_000_000 : 12_000_000)
        }
        self.interactive = interactive
        self.wire = wire
        super.init()

        let encoder = try makeH264Encoder(width: info.width, height: info.height)
        self.encoder = encoder
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: NSNumber(value: 0))
        configureRate()
        VTCompressionSessionPrepareToEncodeFrames(encoder)
    }

    deinit {
        if let encoder = encoder { VTCompressionSessionInvalidate(encoder) }
    }

    func start(completion: @escaping (Error?) -> Void) {
        queue.async {
            self.active = true
            if let stream = self.stream { stream.startCapture(completionHandler: completion) }
            else { completion(nil) }
        }
    }

    func stop() {
        queue.async {
            self.active = false
            self.retry?.cancel()
            self.retry = nil
            self.latestPixels = nil
            self.nativeFrameSince = nil
            self.pendingFrame = false
            self.stream?.stopCapture { _ in }
            self.stream = nil
            if let encoder = self.encoder { VTCompressionSessionInvalidate(encoder) }
            self.encoder = nil
        }
    }

    func submitTestPattern(_ pixels: CVPixelBuffer) {
        queue.async { self.submit(pixels) }
    }

    func submitTestScreenFrame(_ pixels: CVPixelBuffer?, status: SCFrameStatus) {
        queue.async {
            guard self.active else { return }
            self.acceptScreenFrame(pixels, status: status)
        }
    }

    func pauseForUpdate(_ paused: Bool) {
        queue.async {
            guard self.pausedForUpdate != paused else { return }
            self.pausedForUpdate = paused
            self.lastNetworkCheckMS = nil
            self.captured = 0
            self.creditBlocked = 0
            if !paused {
                self.refreshRequested = true
                self.pendingFrame = self.latestPixels != nil
                self.drain()
            }
        }
    }

    func diagnostics() -> SenderStreamDiagnostics {
        queue.sync {
            SenderStreamDiagnostics(id: info.id, targetFPS: tuning.load.frameRate(fps),
                                    targetKbps: targetBitRate / 1_000, reduced: tuning.reduced,
                                    pendingVideoBytes: delivery.enabled ? delivery.outstanding : nil,
                                    baseVideoRoundTripMS: delivery.baseRoundTripMS, videoQueueDelayMS: videoQueueDelayMS,
                                    encodeMS: encodeMS)
        }
    }

    private func configureRate() {
        guard let encoder = encoder else { return }
        let frameRate = tuning.load.frameRate(fps)
        let bitRate = targetBitRate
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: frameRate))
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: bitRate))
        // Cap short spikes while giving the initial keyframe room for clear text.
        let bytes = bitRate / 8
        let limits: [NSNumber] = [NSNumber(value: max(64 * 1024, bytes * 3 / 8)), 0.25]
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_DataRateLimits, value: limits as CFArray)
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: frameRate))
    }

    func adjust(mode: StreamMode, sample: ReceiverDisplayDiagnostics? = nil, roundTripMS: Int? = nil,
                directHigh: Bool? = nil) {
        queue.async { [weak self] in
            guard let self = self else { return }
            let previousRate = self.targetBitRate
            let previousLoad = self.tuning.load
            if let directHigh = directHigh { self.directHigh = directHigh }
            self.tuning.update(mode: mode, sample: sample, roundTripMS: self.delivery.enabled ? nil : roundTripMS)
            if previousLoad != self.tuning.load || previousRate != self.targetBitRate {
                self.configureRate()
                self.drain()
            }
        }
    }

    func acknowledge(_ feedback: VideoFeedback) {
        queue.async { [weak self] in
            guard let self = self, self.active else { return }
            let now = DispatchTime.now().uptimeNanoseconds / 1_000_000
            guard let result = self.delivery.acknowledge(feedback.receivedBytes, atMS: now) else { return }
            if let delay = result.queueDelayMS {
                let waiting = self.delivery.queueDelayWhileWaiting(atMS: now) ?? 0
                self.observeDelivery(extraDelayMS: max(delay, waiting), atMS: now)
            }
            if feedback.requestKeyframe, self.lastRefreshMS.map({ now - $0 >= 450 }) ?? true {
                self.lastRefreshMS = now
                self.refreshRequested = true
                self.pendingFrame = self.latestPixels != nil
            }
            if result.progressed || feedback.requestKeyframe { self.drain() }
        }
    }

    private func observeDelivery(extraDelayMS: Int, atMS now: UInt64) {
        guard !pausedForUpdate else { return }
        let severe = extraDelayMS >= StreamTuning.severeQueueDelayMS
        let interval: UInt64 = severe ? 250 : 1_000
        if let previous = lastNetworkCheckMS {
            guard now - previous >= interval else { return }
        } else if !severe {
            lastNetworkCheckMS = now
            return
        }

        let before = tuning.load
        let blocked = captured >= 15 && creditBlocked * 3 >= captured
        tuning.observeNetwork(extraDelayMS: extraDelayMS, blocked: blocked)
        lastNetworkCheckMS = now
        videoQueueDelayMS = extraDelayMS
        captured = 0
        creditBlocked = 0
        if tuning.load != before { configureRate() }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { [weak self] in
            guard let self = self, self.active else { return }
            self.wire.close(L("화면 전송 종료: \(error.localizedDescription)", "Screen sharing ended: \(error.localizedDescription)"))
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, active else { return }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]]
        guard let rawStatus = attachments?.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus) else { return }
        acceptScreenFrame(sample.imageBuffer, status: status)
    }

    private func acceptScreenFrame(_ pixels: CVPixelBuffer?, status: SCFrameStatus) {
        if info.nativePixels == true, status == .blank || status == .suspended || status == .stopped {
            nativeFrameSince = nil
        }
        guard status == .complete, let pixels else { return }
        if info.nativePixels == true {
            guard CVPixelBufferGetWidth(pixels) == info.width, CVPixelBufferGetHeight(pixels) == info.height else {
                nativeFrameSince = nil
                return
            }
            if nativeFrameSince == nil { nativeFrameSince = .now() }
        }
        submit(pixels)
    }

    private func submit(_ pixels: CVPixelBuffer) {
        guard active else { return }
        latestPixels = pixels
        pendingFrame = true
        if delivery.enabled && !pausedForUpdate {
            captured += 1
            if !delivery.hasRoom(bitrate: targetBitRate) { creditBlocked += 1 }
        }
        drain()
    }

    private func retryDrain(after nanoseconds: UInt64) {
        guard retry == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.retry = nil
            self?.drain()
        }
        retry = work
        queue.asyncAfter(deadline: .now() + .nanoseconds(Int(nanoseconds)), execute: work)
    }

    private func drain() {
        guard active, !pausedForUpdate, pendingFrame, !encoding,
              let encoder = encoder, let pixels = latestPixels else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let nowMS = now / 1_000_000
        // A late receipt is itself a congestion signal, even before an ACK arrives.
        if let delay = delivery.queueDelayWhileWaiting(atMS: nowMS), delay >= StreamTuning.severeQueueDelayMS {
            observeDelivery(extraDelayMS: delay, atMS: nowMS)
        }
        guard delivery.hasRoom(bitrate: targetBitRate) else {
            if delivery.baseRoundTripMS != nil { retryDrain(after: 125_000_000) }
            return
        }
        guard wire.hasVideoRoom(maxPending: interactive ? 48 * 1024 : 128 * 1024) else {
            retryDrain(after: 8_000_000)
            return
        }
        // ScreenCaptureKit already paces full speed. At a reduced rate defer
        // one raw frame rather than dropping the last update on a quiet desktop.
        let frameRate = tuning.load.frameRate(fps)
        let spacing = frameRate < fps ? 1_000_000_000 / UInt64(frameRate) : 0
        if now - lastEncodedAt < spacing {
            retryDrain(after: spacing - (now - lastEncodedAt))
            return
        }
        pendingFrame = false
        encoding = true
        lastEncodedAt = now
        if refreshRequested {
            needKeyframe = true
            refreshRequested = false
        }
        let force = needKeyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        let result = VTCompressionSessionEncodeFrame(
            encoder, imageBuffer: pixels, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            duration: .invalid, frameProperties: force, infoFlagsOut: nil
        ) { [weak self] status, _, encoded in
            guard let self = self else { return }
            let elapsedMS = Double(DispatchTime.now().uptimeNanoseconds - now) / 1_000_000
            self.queue.async {
                guard self.active else { return }
                self.encoding = false
                if !self.pausedForUpdate, status == noErr, let encoded = encoded {
                    self.encodeMS = (self.encodeMS ?? elapsedMS) * 0.8 + elapsedMS * 0.2
                    self.send(encoded)
                } else {
                    self.needKeyframe = true
                }
                self.drain()
            }
        }
        if result != noErr { encoding = false; needKeyframe = true }
    }

    private func send(_ sample: CMSampleBuffer) {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
            as? [[CFString: Any]]
        let sync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool != true
        if needKeyframe && !sync { return }
        if !sentFormat || needKeyframe {
            guard let format = sample.formatDescription else { return }
            var params = Data()
            var nalLength: Int32 = 0
            for index in 0..<2 {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: &nalLength)
                guard status == noErr, let pointer = pointer, (1...4000).contains(size) else { return }
                params.put(UInt32(size))
                params.append(pointer, count: size)
            }
            params.put(UInt32(nalLength))
            guard wire.send(.format, screen: info.id, data: params) else { needKeyframe = true; return }
            sentFormat = true
        }
        guard let block = sample.dataBuffer else { return }
        let length = CMBlockBufferGetDataLength(block)
        guard length > 0, length < Wire.maxFrame else { needKeyframe = true; return }
        var bytes = Data(count: length + 1)
        bytes[0] = sync ? 1 : 0
        let result = bytes.withUnsafeMutableBytes { buffer in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: buffer.baseAddress!.advanced(by: 1))
        }
        needKeyframe = result != noErr || !wire.send(.video, screen: info.id, data: bytes)
        if !needKeyframe && info.videoFeedback == true {
            delivery.record(bytes.count, atMS: DispatchTime.now().uptimeNanoseconds / 1_000_000)
        }
    }
}

struct ScreenshotClipboard {
    static func representations(_ image: CGImage) -> (png: Data, tiff: Data?)? {
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        return (png, bitmap.tiffRepresentation(using: .lzw, factor: 1))
    }

    static func write(_ image: (png: Data, tiff: Data?), to pasteboard: NSPasteboard) -> Bool {
        let item = NSPasteboardItem()
        guard item.setData(image.png, forType: .png) else { return false }
        if let tiff = image.tiff { item.setData(tiff, forType: .tiff) }
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }
}

@available(macOS 14.0, *)
private final class HostInput {
    private var source: CGEventSource?
    private var keys: [UInt16: Int64] = [:]
    private var modifierKeys = Set<UInt16>()
    private var lastFlags: CGEventFlags = []
    private var buttons = Set<Int>()
    private var point = CGPoint.zero
    private var scrollPoint = CGPoint.zero
    private var scrolling = SessionScroll()
    private let keyboardLayout = SessionKeyboardLayout()
    private var macInputMatching = false
    private var screenshot: Process?
    private var screenshotID: UUID?
    private var deferredPastePID: pid_t?
    private var swallowedPasteUp = false
    private var swallowedScreenshotUp = false
    private var smartZoomApp: String?
    private var koreanPair: (korean: String, english: String)?
    var supportsKoreanCaps: Bool { koreanPair != nil }
    private var lastKeyboardRequest: String?
    private(set) var keyboardLayoutResult: KeyboardLayoutResult?
    private(set) var screenshotCopied: Bool?

    func beginSession(macInputMatching: Bool) {
        self.macInputMatching = macInputMatching
        source = macInputMatching
            ? CGEventSource(stateID: .privateState) ?? CGEventSource(stateID: .combinedSessionState)
            : CGEventSource(stateID: .hidSystemState)
        if macInputMatching { source?.localEventsSuppressionInterval = 0 }
        koreanPair = macInputMatching ? MacInputSource.koreanPair() : nil
        lastKeyboardRequest = nil
        keyboardLayoutResult = nil
        screenshotCopied = nil
    }

    func endSession() {
        release()
        keyboardLayout.finish()
        if let capture = screenshot, capture.isRunning { capture.terminate() }
        screenshot = nil
        screenshotID = nil
        smartZoomApp = nil
        koreanPair = nil
        source = nil
    }

    func release() {
        deferredPastePID = nil
        swallowedPasteUp = false
        swallowedScreenshotUp = false
        if let cancel = scrolling.end(source: source) {
            cancel.location = scrollPoint
            cancel.flags = lastFlags
            cancel.post(tap: .cgSessionEventTap)
        }
        for key in keys.keys.sorted() where !modifierKeys.contains(key) {
            postKey(key, down: false, flags: lastFlags, keyboardType: keys[key])
        }
        for button in buttons.sorted() { mouse(.up, button, 1, flags: lastFlags) }
        buttons.removeAll()
        for key in modifierKeys.sorted() {
            modifierKeys.remove(key)
            if let modifier = MacModifierKey.matching(key) {
                var mask = modifier.sideMask
                if !modifierKeys.contains(where: { MacModifierKey.matching($0)?.flag == modifier.flag }) {
                    mask |= UInt64(modifier.flag.rawValue)
                }
                lastFlags = CGEventFlags(rawValue: lastFlags.rawValue & ~mask)
            }
            postKey(key, down: false, flags: lastFlags, keyboardType: keys[key], modifier: true)
        }
        keys.removeAll()
        lastFlags = []
    }

    func handle(_ input: Input, capture: Capture?) {
        let flags = CGEventFlags(rawValue: input.flags & MacModifierKey.supportedFlags)
        switch input.action {
        case .release: release()
        case .cursorShapes: break
        case .inputSource:
            guard macInputMatching, let id = input.keyboardInputSource,
                  MacInputSource.validID(id), id != lastKeyboardRequest else { return }
            lastKeyboardRequest = id
            keyboardLayoutResult = keyboardLayout.match(id)
        case .koreanCaps:
            guard let pair = koreanPair, let current = MacInputSource.currentID() else { return }
            let next = current == pair.korean ? pair.english : pair.korean
            lastKeyboardRequest = nil
            keyboardLayoutResult = keyboardLayout.match(next)
        case .screenshotFull, .screenshotArea, .screenshotOptions:
            guard macInputMatching, let capture = capture else { return }
            if input.action == .screenshotFull || input.screenshotRegion != nil {
                captureToClipboard(capture, region: input.action == .screenshotArea ? input.screenshotRegion : nil)
            } else {
                // Receivers before 0.8 still send native interactive capture actions.
                captureLegacySelection(input.action)
            }
        case .missionControl:
            if !openSystemUtility("Mission Control"), let binding = ShortcutBinding.current(input.action) {
                postShortcut(binding)
            }
        case .launchApps:
            if !openSystemUtility("Apps") { _ = openSystemUtility("Launchpad") }
        case .smartZoom:
            if let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier, app == "com.apple.Safari" {
                let reset = smartZoomApp == app
                postShortcut(ShortcutBinding(key: reset ? kVK_ANSI_0 : kVK_ANSI_Equal, flags: .maskCommand))
                smartZoomApp = reset ? nil : app
            }
        case .rotateLeft, .rotateRight:
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.Photos" {
                let flags: CGEventFlags = input.action == .rotateLeft ? .maskCommand : [.maskCommand, .maskAlternate]
                postShortcut(ShortcutBinding(key: kVK_ANSI_R, flags: flags))
            }
        case .spacePrevious, .spaceNext, .appWindows, .zoomIn, .zoomOut, .showDesktop, .lookup,
             .notificationCenter, .pagePrevious, .pageNext:
            if let binding = ShortcutBinding.current(input.action) { postShortcut(binding) }
        case .keyDown, .keyUp, .flags:
            guard (0...127).contains(input.a) else { return }
            let key = UInt16(input.a)
            if macInputMatching, key == UInt16(kVK_ANSI_3) {
                if input.action == .keyUp && swallowedScreenshotUp {
                    swallowedScreenshotUp = false
                    return
                }
                let chords: CGEventFlags = [.maskCommand, .maskShift, .maskControl, .maskAlternate]
                if input.action == .keyDown, let capture = capture,
                   flags.intersection(chords) == [.maskControl, .maskAlternate, .maskCommand] {
                    swallowedScreenshotUp = true
                    if input.repeatKey != true { captureToClipboard(capture, region: nil) }
                    return
                }
            }
            if key == UInt16(kVK_ANSI_V) {
                if input.action == .keyUp && swallowedPasteUp {
                    swallowedPasteUp = false
                    return
                }
                let chords: CGEventFlags = [.maskCommand, .maskShift, .maskControl, .maskAlternate]
                if input.action == .keyDown, screenshotID != nil, flags.intersection(chords) == .maskCommand {
                    swallowedPasteUp = true
                    if input.repeatKey != true {
                        deferredPastePID = NSWorkspace.shared.frontmostApplication?.processIdentifier
                    }
                    return
                }
            }
            let modifier = input.action == .flags
            let down = input.action == .keyDown || (modifier && input.b == 1)
            let keyboardType = input.keyboardType.flatMap { (0...65_535).contains($0) ? $0 : nil } ?? keys[key]
            if key != UInt16(kVK_CapsLock) {
                if down {
                    keys[key] = keyboardType ?? -1
                    if modifier { modifierKeys.insert(key) }
                } else {
                    keys.removeValue(forKey: key)
                    modifierKeys.remove(key)
                }
            }
            lastFlags = flags
            postKey(key, down: down, flags: flags, keyboardType: keyboardType,
                    modifier: modifier, repeated: input.repeatKey == true)
        case .move, .down, .up, .scroll, .gesture:
            guard input.x.isFinite, input.y.isFinite, (0...1).contains(input.x), (0...1).contains(input.y),
                  CGDisplayIsActive(input.display) != 0 else { return }
            let display = CGDisplayBounds(input.display)
            point = CGPoint(x: display.minX + input.x * max(0, display.width - 1),
                            y: display.minY + input.y * max(0, display.height - 1))
            if input.action == .gesture {
                guard let data = input.gestureData, data.count <= 4096,
                      let event = StudioCreateEvent(data as CFData),
                      let gesture = NSEvent(cgEvent: event), isRemoteGesture(gesture.type) else { return }
                event.location = point
                event.flags = flags
                event.timestamp = DispatchTime.now().uptimeNanoseconds
                event.post(tap: .cghidEventTap)
                return
            }
            if input.action == .scroll {
                if let motion = input.scrollMotion {
                    scrollPoint = point
                    if let event = scrolling.makeEvent(motion, phase: input.scrollPhase,
                                                       momentum: input.momentumPhase, source: source) {
                        event.location = point
                        event.flags = flags
                        // These deltas already follow the receiver's settings.
                        event.post(tap: .cgSessionEventTap)
                    }
                    return
                }
                let vertical = Int32(clamping: max(-400, min(400, input.a)))
                let horizontal = Int32(clamping: max(-400, min(400, input.b)))
                let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                                    wheel1: vertical, wheel2: horizontal, wheel3: 0)
                event?.location = point
                event?.flags = flags
                if let phase = input.scrollPhase, [0, 1, 2, 4, 8, 128].contains(phase) {
                    event?.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
                }
                if let phase = input.momentumPhase, (0...3).contains(phase) {
                    event?.setIntegerValueField(.scrollWheelEventMomentumPhase, value: phase)
                }
                event?.post(tap: .cghidEventTap)
                return
            }
            guard (0...31).contains(input.a) else { return }
            if input.action == .down { buttons.insert(input.a) }
            if input.action == .up { buttons.remove(input.a) }
            mouse(input.action, input.a, input.b, flags: flags, pressure: input.pressure)
        }
    }

    private func openSystemUtility(_ name: String) -> Bool {
        let url = URL(fileURLWithPath: "/System/Applications/\(name).app", isDirectory: true)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        return NSWorkspace.shared.open(url)
    }

    private func captureToClipboard(_ capture: Capture, region: ScreenshotRegion?) {
        guard screenshotID == nil, screenshot?.isRunning != true else { return }
        let id = UUID()
        screenshotID = id
        capture.screenshot(region) { [weak self] image in
            DispatchQueue.global(qos: .userInitiated).async {
                let data = image.flatMap(ScreenshotClipboard.representations)
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.screenshotID == id else { return }
                    self.screenshotID = nil
                    let pastePID = self.deferredPastePID
                    self.deferredPastePID = nil
                    let copied = data.map { ScreenshotClipboard.write($0, to: .general) } ?? false
                    self.screenshotCopied = copied
                    guard copied else { return }
                    if let pid = pastePID, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
                        self.postShortcut(ShortcutBinding(key: kVK_ANSI_V, flags: .maskCommand))
                    }
                }
            }
        }
    }

    private func captureLegacySelection(_ action: Input.Action) {
        guard screenshotID == nil, screenshot?.isRunning != true else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = action == .screenshotOptions ? ["-i", "-U", "-c", "-x"] : ["-i", "-c", "-x"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run(); screenshot = process }
        catch { screenshot = nil }
    }

    private func postKey(_ key: UInt16, down: Bool, flags: CGEventFlags, keyboardType: Int64?,
                         modifier: Bool = false, repeated: Bool = false) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { return }
        event.flags = flags
        if let keyboardType = keyboardType, keyboardType >= 0 {
            event.setIntegerValueField(.keyboardEventKeyboardType, value: keyboardType)
        }
        if modifier { event.type = .flagsChanged }
        if repeated { event.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
        event.post(tap: .cghidEventTap)
    }

    private func postShortcut(_ binding: ShortcutBinding) {
        var flags = CGEventSource.flagsState(.combinedSessionState).union(lastFlags)
        let modifiers: [(CGEventFlags, Int)] = [
            (.maskControl, kVK_Control), (.maskShift, kVK_Shift), (.maskAlternate, kVK_Option),
            (.maskCommand, kVK_Command), (.maskSecondaryFn, kVK_Function)
        ]
        let pressed = modifiers.filter { binding.flags.contains($0.0) && !flags.contains($0.0) }
        func post(_ key: Int, down: Bool, flags: CGEventFlags, modifier: Bool = false) {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: UInt16(key), keyDown: down) else { return }
            if modifier { event.type = .flagsChanged }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
        for (flag, key) in pressed {
            flags.insert(flag)
            post(key, down: true, flags: flags, modifier: true)
        }
        post(binding.key, down: true, flags: binding.flags)
        post(binding.key, down: false, flags: binding.flags)
        for (flag, key) in pressed.reversed() {
            flags.remove(flag)
            post(key, down: false, flags: flags, modifier: true)
        }
    }

    private func mouse(_ action: Input.Action, _ button: Int, _ count: Int, flags: CGEventFlags, pressure: Double? = nil) {
        let mouseButton: CGMouseButton = button == 0 ? .left : button == 1 ? .right : .center
        let family = min(button, 2)
        let types: [[CGEventType]] = [
            [.leftMouseDown, .leftMouseUp, .leftMouseDragged],
            [.rightMouseDown, .rightMouseUp, .rightMouseDragged],
            [.otherMouseDown, .otherMouseUp, .otherMouseDragged]
        ]
        let type: CGEventType
        switch action {
        case .down: type = types[family][0]
        case .up: type = types[family][1]
        default: type = buttons.contains(button) ? types[family][2] : .mouseMoved
        }
        let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: mouseButton)
        event?.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
        if let pressure = pressure, pressure.isFinite {
            event?.setDoubleValueField(.mouseEventPressure, value: max(0, min(1, pressure)))
        }
        if action == .down || action == .up {
            event?.setIntegerValueField(.mouseEventClickState, value: Int64(max(1, min(count, 3))))
        }
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
    }
}

struct CaptureGeometry {
    static func outputSize(logical: CGSize, source: CGSize, nativeScale: CGFloat, retina: Bool) -> CGSize {
        let maxWidth: CGFloat = retina ? 2560 : 1920
        let maxHeight: CGFloat = retina ? 1600 : 1200
        let scale = min(nativeScale * source.width / logical.width, nativeScale * source.height / logical.height,
                        maxWidth / logical.width, maxHeight / logical.height)
        func even(_ value: CGFloat) -> Int { max(2, Int(value.rounded(.down)) & ~1) }
        return CGSize(width: even(logical.width * scale), height: even(logical.height * scale))
    }
}

private final class SessionNativeDisplay {
    let id: CGDirectDisplayID
    private let token: CFTypeRef
    private let original: CGDirectDisplayID
    private let pixels: ReceiverNativePixels

    var isMirrored: Bool { CGDisplayMirrorsDisplay(original) == id }

    var isStandalone: Bool {
        guard CGMainDisplayID() == id else { return false }
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return false }
        let capacity = count + 1
        var displays = [CGDirectDisplayID](repeating: kCGNullDirectDisplay, count: Int(capacity))
        guard CGGetOnlineDisplayList(capacity, &displays, &count) == .success, count < capacity else { return false }
        let online = displays.prefix(Int(count))
        return online.contains(id) && !online.contains(original)
    }

    var hasExpectedLogicalSize: Bool {
        let bounds = CGDisplayBounds(id)
        return bounds.width * 2 == CGFloat(pixels.width) && bounds.height * 2 == CGFloat(pixels.height)
    }

    init?(_ pixels: ReceiverNativePixels) {
        let original = CGMainDisplayID()
        guard original != kCGNullDirectDisplay, CGDisplayIsInMirrorSet(original) == 0 else { return nil }
        var display = kCGNullDirectDisplay
        guard let token = StudioCreateVirtualDisplay(UInt32(pixels.width), UInt32(pixels.height), &display) else { return nil }
        self.id = display
        self.token = token
        self.original = original
        self.pixels = pixels
    }

    func activate() -> Bool {
        if isMirrored { return true }
        // With no monitor attached, macOS replaces its placeholder with this virtual primary display.
        if isStandalone { return hasExpectedLogicalSize }
        guard CGDisplayIsActive(id) != 0, CGDisplayIsOnline(original) == 1,
              CGDisplayIsInMirrorSet(original) == 0,
              let modes = CGDisplayCopyAllDisplayModes(id, [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary)
                  as? [CGDisplayMode],
              let mode = modes.first(where: {
                  $0.pixelWidth == pixels.width && $0.pixelHeight == pixels.height &&
                  $0.width * 2 == pixels.width && $0.height * 2 == pixels.height &&
                  $0.isUsableForDesktopGUI()
              }) else { return false }
        return configure(source: id, mode: mode)
    }

    func restore() {
        if isMirrored { _ = configure(source: kCGNullDirectDisplay) }
    }

    private func configure(source: CGDirectDisplayID, mode: CGDisplayMode? = nil) -> Bool {
        var configuration: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&configuration) == .success, let configuration = configuration else { return false }
        if let mode = mode, CGConfigureDisplayWithDisplayMode(configuration, source, mode, nil) != .success {
            CGCancelDisplayConfiguration(configuration)
            return false
        }
        guard CGConfigureDisplayMirrorOfDisplay(configuration, original, source) == .success else {
            CGCancelDisplayConfiguration(configuration)
            return false
        }
        return CGCompleteDisplayConfiguration(configuration, .forAppOnly) == .success
    }
}

struct MatchedDisplay {
    let id: CGDirectDisplayID
    let original: CGDisplayMode?
    let applied: CGDisplayMode

    var isApplied: Bool {
        guard let current = CGDisplayCopyDisplayMode(id) else { return false }
        return Self.same(current, applied)
    }

    static func candidate(for id: CGDirectDisplayID, options: ReceiverDisplayOptions, retina: Bool,
                          nativePixels: ReceiverNativePixels? = nil) -> CGDisplayMode? {
        let maxWidth = retina ? 2560 : 1920
        let maxHeight = retina ? 1600 : 1200
        let modes = CGDisplayCopyAllDisplayModes(id, [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary)
            as? [CGDisplayMode] ?? []
        if let nativePixels = nativePixels {
            return modes.filter {
                $0.isUsableForDesktopGUI() && ($0.refreshRate == 0 || $0.refreshRate >= 50) &&
                nativePixels.fitsSource(width: $0.pixelWidth, height: $0.pixelHeight) &&
                options.hasMatchingAspect(width: $0.width, height: $0.height)
            }.min {
                let firstArea = $0.pixelWidth * $0.pixelHeight
                let secondArea = $1.pixelWidth * $1.pixelHeight
                if firstArea != secondArea { return firstArea < secondArea }
                let first = abs($0.width - options.width) + abs($0.height - options.height)
                let second = abs($1.width - options.width) + abs($1.height - options.height)
                return first < second
            }
        }
        let matching = modes.filter {
            $0.isUsableForDesktopGUI() && $0.pixelWidth >= 1200 && $0.pixelHeight >= 720 &&
            $0.pixelWidth <= maxWidth && $0.pixelHeight <= maxHeight &&
            ($0.refreshRate == 0 || $0.refreshRate >= 50) &&
            options.hasMatchingAspect(width: $0.width, height: $0.height)
        }
        let exact = matching.filter { $0.width * options.height == $0.height * options.width }
        return (exact.isEmpty ? matching : exact).min {
            let first = abs($0.width - options.width) + abs($0.height - options.height)
            let second = abs($1.width - options.width) + abs($1.height - options.height)
            if first != second { return first < second }
            let firstRefresh = abs($0.refreshRate - 60), secondRefresh = abs($1.refreshRate - 60)
            if firstRefresh != secondRefresh { return firstRefresh < secondRefresh }
            return $0.pixelWidth * $0.pixelHeight > $1.pixelWidth * $1.pixelHeight
        }
    }

    static func apply(_ options: ReceiverDisplayOptions, retina: Bool,
                      nativePixels: ReceiverNativePixels? = nil) -> Self? {
        let id = CGMainDisplayID()
        guard CGDisplayIsActive(id) != 0, CGDisplayIsInMirrorSet(id) == 0,
              CGDisplayRotation(id) == 0, let current = CGDisplayCopyDisplayMode(id),
              let target = candidate(for: id, options: options, retina: retina, nativePixels: nativePixels) else { return nil }
        if same(current, target) { return Self(id: id, original: nil, applied: current) }
        guard CGDisplaySetDisplayMode(id, target, nil) == .success else { return nil }
        return Self(id: id, original: current, applied: target)
    }

    func restore() {
        guard let original = original, CGDisplayIsActive(id) != 0,
              let current = CGDisplayCopyDisplayMode(id), Self.same(current, applied) else { return }
        CGDisplaySetDisplayMode(id, original, nil)
    }

    private static func same(_ first: CGDisplayMode, _ second: CGDisplayMode) -> Bool {
        first.ioDisplayModeID == second.ioDisplayModeID && first.pixelWidth == second.pixelWidth &&
        first.pixelHeight == second.pixelHeight
    }
}

struct ShortcutBinding {
    let key: Int
    let flags: CGEventFlags

    static func current(_ action: Input.Action) -> Self? {
        let shortcuts = UserDefaults(suiteName: "com.apple.symbolichotkeys")?
            .dictionary(forKey: "AppleSymbolicHotKeys")
        return resolve(action, shortcuts: shortcuts ?? [:])
    }

    static func resolve(_ action: Input.Action, shortcuts: [String: Any]) -> Self? {
        let id: String
        let fallback: Self?
        switch action {
        case .spacePrevious: id = "79"; fallback = Self(key: kVK_LeftArrow, flags: .maskControl)
        case .spaceNext: id = "81"; fallback = Self(key: kVK_RightArrow, flags: .maskControl)
        case .missionControl: id = "32"; fallback = Self(key: kVK_UpArrow, flags: .maskControl)
        case .appWindows: id = "33"; fallback = Self(key: kVK_DownArrow, flags: .maskControl)
        case .showDesktop: id = "36"; fallback = Self(key: kVK_F11, flags: .maskSecondaryFn)
        case .notificationCenter: id = "163"; fallback = nil
        case .lookup: return Self(key: kVK_ANSI_D, flags: [.maskControl, .maskCommand])
        case .pagePrevious: return Self(key: kVK_ANSI_LeftBracket, flags: .maskCommand)
        case .pageNext: return Self(key: kVK_ANSI_RightBracket, flags: .maskCommand)
        case .zoomIn: return Self(key: kVK_ANSI_Equal, flags: [.maskCommand, .maskShift])
        case .zoomOut: return Self(key: kVK_ANSI_Minus, flags: .maskCommand)
        default: return nil
        }
        guard let entry = shortcuts[id] as? [String: Any] else { return fallback }
        guard entry["enabled"] as? Bool != false,
              let value = entry["value"] as? [String: Any],
              let parameters = value["parameters"] as? [NSNumber], parameters.count == 3,
              (0...127).contains(parameters[1].intValue) else { return nil }
        let flags = CGEventFlags(rawValue: parameters[2].uint64Value & 0x00fe0000)
        return Self(key: parameters[1].intValue, flags: flags)
    }
}
