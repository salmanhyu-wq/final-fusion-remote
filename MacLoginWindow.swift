import AppKit
import Network

// The built-in Screen Sharing client handles the Mac account credential
// prompt. This bridge only transfers bytes over the existing pinned TLS link.
//
// Screen Sharing probes the Mac on one connection, closes it when the password
// is submitted and signs in on a new one, so the bridge keeps listening and
// carries every local connection over the same approved link.
final class MacLoginWindow {
    private enum Frame: UInt8 { case open = 1, data, close, keepAlive }

    private final class Stream {
        let number: Int
        let connection: NWConnection
        var toMac = 0
        var toViewer = 0
        init(number: Int, connection: NWConnection) {
            self.number = number
            self.connection = connection
        }
    }

    private static let frameLimit = 32_768
    private static let streamLimit = 8
    private static let screenSharingID = "com.apple.ScreenSharing"

    private let remote: NWConnection
    private var listener: NWListener?
    private var streams: [UInt16: Stream] = [:]
    private var nextStream: UInt16 = 1
    private var streamCount = 0
    private var accepted = false
    private var account = ""
    private var startTimeout: DispatchWorkItem?
    private var idleTimeout: DispatchWorkItem?
    private var keepAlive: DispatchSourceTimer?
    private var lastHeard = Date()
    private var activity: NSObjectProtocol?
    private var closeScreenSharing = false
    private var finished = false
    /// `handoff` is true when the host Mac ended an approved link, which is
    /// what happens once someone signs in there.
    var onFinish: ((_ handoff: Bool, _ reason: String) -> Void)?

    init(remote: NWConnection) { self.remote = remote }

    func start(greeting: Data) {
        let timeout = DispatchWorkItem { [weak self] in
            self?.finish(handoff: false, L("Mac 로그인 화면을 열지 못했어요.", "Couldn't open the Mac login screen."))
        }
        startTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: timeout)

        var header = Data([Kind.hello.rawValue])
        header.put(UInt32(0))
        header.put(UInt32(49))
        header.append(greeting.prefix(48))
        header.append(0)
        remote.send(content: header, completion: .contentProcessed { [weak self] error in
            guard let self, !self.finished else { return }
            if let error { self.finish(handoff: false, error.localizedDescription); return }
            self.read(1) { [weak self] reply in
                guard let self else { return }
                switch reply.first {
                case 1: self.readAccount()
                case 0:
                    self.finish(handoff: false, L("로그인 전에 연결하려면 보내는 맥에 로그인해 이 기기를 먼저 허용하세요.",
                                                  "Sign in to the host Mac and approve this device before connecting at startup."))
                default:
                    self.finish(handoff: false, L("보내는 맥의 기본 화면 공유에 연결하지 못했어요. 보내는 맥에서 화면 공유가 켜져 있는지 확인하세요.",
                                                  "Couldn't connect to the host Mac's built-in Screen Sharing. Make sure Screen Sharing is on there."))
                }
            }
        })
    }

    func stop() {
        onFinish = nil
        finish(handoff: false, "")
    }

    // The approved host names its own account so the prompt only needs the password.
    private func readAccount() {
        read(1) { [weak self] length in
            guard let self else { return }
            let count = Int(length[0])
            guard count > 0 else { self.begin(); return }
            self.read(count) { [weak self] name in
                guard let self else { return }
                if let name = String(data: name, encoding: .utf8),
                   !name.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) {
                    self.account = name
                }
                self.begin()
            }
        }
    }

    private func begin() {
        accepted = true
        lastHeard = Date()
        // Screen Sharing covers this app while the password is typed. Keep the
        // link's timers running instead of letting macOS nap the app.
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                         reason: "Mac login window link")
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self, !self.finished else { return }
            if Date().timeIntervalSince(self.lastHeard) > 45 {
                NSLog("Final Fusion login: host stopped answering")
                self.finish(handoff: true, "")
            } else { self.send(.keepAlive, 0) }
        }
        keepAlive = timer
        timer.resume()
        readFrame()
        listen()
    }

    private func listen() {
        let parameters = tcpParameters()
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        do {
            let listener = try NWListener(using: parameters)
            self.listener = listener
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, !self.finished else { return }
                switch state {
                case .ready:
                    if let port = listener?.port { self.openScreenSharing(port) }
                case let .failed(error): self.finish(handoff: false, error.localizedDescription)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self, !self.finished, self.streams.count < Self.streamLimit,
                      case let .hostPort(.ipv4(ip), _) = connection.endpoint,
                      ip == IPv4Address("127.0.0.1") else { connection.cancel(); return }
                self.accept(connection)
            }
            listener.start(queue: .main)
        } catch { finish(handoff: false, error.localizedDescription) }
    }

    private func accept(_ connection: NWConnection) {
        var id = nextStream
        while id == 0 || streams[id] != nil { id &+= 1 }
        nextStream = id &+ 1
        streamCount += 1
        let stream = Stream(number: streamCount, connection: connection)
        streams[id] = stream
        startTimeout?.cancel()
        startTimeout = nil
        idleTimeout?.cancel()
        idleTimeout = nil
        connection.stateUpdateHandler = { [weak self, weak stream] state in
            guard let self, let stream, !self.finished, self.streams[id] === stream else { return }
            switch state {
            case .ready:
                NSLog("Final Fusion login: screen sharing connection %ld opened", stream.number)
                self.send(.open, id)
                self.pump(id, stream)
            case .failed, .cancelled: self.close(id, stream, by: "viewer", tellHost: true)
            default: break
            }
        }
        connection.start(queue: .main)
    }

    private func openScreenSharing(_ port: NWEndpoint.Port) {
        var address = URLComponents()
        address.scheme = "vnc"
        address.host = "127.0.0.1"
        address.port = Int(port.rawValue)
        if !account.isEmpty { address.user = account }
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.screenSharingID),
              app.path.hasPrefix("/System/"), let url = address.url else {
            finish(handoff: false, L("이 Mac에서 기본 화면 공유 앱을 찾을 수 없어요.", "Couldn't find the built-in Screen Sharing app."))
            return
        }
        // Leave Screen Sharing alone afterwards if it was already in use.
        closeScreenSharing = NSRunningApplication.runningApplications(withBundleIdentifier: Self.screenSharingID).isEmpty
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: .init()) { [weak self] _, error in
            if let error { DispatchQueue.main.async { self?.finish(handoff: false, error.localizedDescription) } }
        }
    }

    // MARK: Local Screen Sharing connections

    private func pump(_ id: UInt16, _ stream: Stream) {
        stream.connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self, weak stream] data, _, complete, error in
            guard let self, let stream, !self.finished, self.streams[id] === stream else { return }
            guard let data, !data.isEmpty, error == nil else {
                self.close(id, stream, by: "viewer", tellHost: true)
                return
            }
            stream.toMac += data.count
            self.send(.data, id, data) { [weak self, weak stream] in
                guard let self, let stream, !self.finished, self.streams[id] === stream else { return }
                if complete { self.close(id, stream, by: "viewer", tellHost: true) }
                else { self.pump(id, stream) }
            }
        }
    }

    private func close(_ id: UInt16, _ stream: Stream, by side: String, tellHost: Bool) {
        guard streams[id] === stream else { return }
        streams[id] = nil
        stream.connection.stateUpdateHandler = nil
        NSLog("Final Fusion login: screen sharing connection %ld closed first by %@: viewer to Mac %ld bytes, Mac to viewer %ld bytes",
              stream.number, side, stream.toMac, stream.toViewer)
        if tellHost {
            send(.close, id)
            stream.connection.cancel()
        } else {
            // Deliver what the Mac already sent before closing the local side.
            let connection = stream.connection
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed { _ in connection.cancel() })
        }
        guard streams.isEmpty, !finished else { return }
        // A wrong password or a closed window leaves no connection. Keep the
        // link for another attempt, then give the host's relay slot back.
        let idle = DispatchWorkItem { [weak self] in
            guard let self, self.streams.isEmpty else { return }
            self.finish(handoff: false, L("Mac 화면 공유 창이 닫혀 로그인 화면 연결을 끝냈어요. 다시 연결해 주세요.",
                                          "The Screen Sharing window closed, so the login screen connection ended. Connect again."))
        }
        idleTimeout = idle
        DispatchQueue.main.asyncAfter(deadline: .now() + 120, execute: idle)
    }

    // MARK: Approved link to the host Mac

    private func send(_ kind: Frame, _ id: UInt16, _ payload: Data = Data(), then: (() -> Void)? = nil) {
        var frame = Data([kind.rawValue, UInt8(id >> 8), UInt8(id & 0xff),
                          UInt8(payload.count >> 8), UInt8(payload.count & 0xff)])
        frame.append(payload)
        remote.send(content: frame, completion: .contentProcessed { [weak self] error in
            guard let self, !self.finished else { return }
            if let error {
                NSLog("Final Fusion login: link send failed: %@", error.localizedDescription)
                self.finish(handoff: self.accepted, "")
            } else { then?() }
        })
    }

    private func read(_ count: Int, then: @escaping (Data) -> Void) {
        remote.receive(minimumIncompleteLength: count, maximumLength: count) { [weak self] data, _, _, error in
            guard let self, !self.finished else { return }
            guard let data, data.count == count else {
                if let error { NSLog("Final Fusion login: link ended: %@", error.localizedDescription) }
                else { NSLog("Final Fusion login: host closed the link") }
                self.finish(handoff: self.accepted, self.accepted ? "" :
                    L("보내는 맥의 로그인 화면에 연결하지 못했어요.", "Couldn't reach the host Mac's login screen."))
                return
            }
            then(data)
        }
    }

    private func readFrame() {
        read(5) { [weak self] header in
            guard let self else { return }
            let bytes = [UInt8](header)
            let id = UInt16(bytes[1]) << 8 | UInt16(bytes[2])
            let length = Int(bytes[3]) << 8 | Int(bytes[4])
            guard let kind = Frame(rawValue: bytes[0]), length <= Self.frameLimit else {
                NSLog("Final Fusion login: host sent an unknown frame")
                self.finish(handoff: true, "")
                return
            }
            if length == 0 { self.handle(kind, id, Data()) }
            else { self.read(length) { [weak self] payload in self?.handle(kind, id, payload) } }
        }
    }

    private func handle(_ kind: Frame, _ id: UInt16, _ payload: Data) {
        lastHeard = Date()
        switch kind {
        case .data:
            guard let stream = streams[id], !payload.isEmpty else { readFrame(); return }
            stream.toViewer += payload.count
            // Read the next frame only after the local side took this one.
            stream.connection.send(content: payload, completion: .contentProcessed { [weak self, weak stream] error in
                guard let self, !self.finished else { return }
                if error != nil, let stream { self.close(id, stream, by: "viewer", tellHost: true) }
                self.readFrame()
            })
        case .close:
            if let stream = streams[id] { close(id, stream, by: "the Mac", tellHost: false) }
            readFrame()
        case .keepAlive, .open:
            readFrame()
        }
    }

    private func finish(handoff: Bool, _ reason: String) {
        guard !finished else { return }
        finished = true
        startTimeout?.cancel()
        startTimeout = nil
        idleTimeout?.cancel()
        idleTimeout = nil
        keepAlive?.cancel()
        keepAlive = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        listener?.cancel()
        listener = nil
        for stream in streams.values {
            stream.connection.stateUpdateHandler = nil
            stream.connection.cancel()
            NSLog("Final Fusion login: screen sharing connection %ld closed with the link: viewer to Mac %ld bytes, Mac to viewer %ld bytes",
                  stream.number, stream.toMac, stream.toViewer)
        }
        streams.removeAll()
        remote.cancel()
        if closeScreenSharing {
            // Its window would otherwise stay behind showing a lost connection.
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: Self.screenSharingID) { app.terminate() }
        }
        let callback = onFinish
        onFinish = nil
        callback?(handoff, reason)
    }
}
