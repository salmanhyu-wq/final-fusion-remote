import Foundation
import Network

// The local socket carries the inner, certificate-pinned TLS stream.
final class RelayTunnel: NSObject, URLSessionWebSocketDelegate {
    private let queue = DispatchQueue(label: "studio.remote.relay")
    private var listener: NWListener?
    private var peer: NWConnection?
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var opened = false
    private var peerReady = false
    private var pumping = false
    private var stopped = false
    private var onEndpoint: ((NWEndpoint.Port) -> Void)?
    private var onFailure: (() -> Void)?

    func start(_ profile: ReceiverProfile, onEndpoint: @escaping (NWEndpoint.Port) -> Void,
               onFailure: @escaping () -> Void) throws {
        guard var address = URLComponents(string: profile.relay), profile.valid else {
            throw StudioError.message(L("받는 앱의 연결 설정을 읽을 수 없어요.", "Couldn't read the viewer app's connection settings."))
        }
        address.scheme = "wss"
        address.path = "/v1/receiver/" + profile.room.lowercased()
        guard let url = address.url else { throw StudioError.message(L("연결 서버 주소를 확인하세요.", "Check the connection server address.")) }

        let parameters = tcpParameters()
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        self.onEndpoint = onEndpoint
        self.onFailure = onFailure
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        var request = URLRequest(url: url)
        request.networkServiceType = .responsiveData
        let socket = session.webSocketTask(with: request)
        socket.maximumMessageSize = 65536
        self.socket = socket

        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self = self, !self.stopped else { return }
            switch state {
            case .ready:
                if let port = listener?.port, let callback = self.onEndpoint {
                    self.onEndpoint = nil
                    DispatchQueue.main.async { callback(port) }
                }
            case .failed: self.finish(notify: true)
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self = self, !self.stopped, self.peer == nil,
                  case let .hostPort(.ipv4(ip), _) = connection.endpoint,
                  ip == IPv4Address("127.0.0.1") else { connection.cancel(); return }
            self.peer = connection
            self.listener?.cancel()
            self.listener = nil
            connection.stateUpdateHandler = { [weak self] state in
                guard let self = self, !self.stopped else { return }
                switch state {
                case .ready:
                    self.peerReady = true
                    self.pumpIfReady()
                case .failed, .cancelled: self.finish(notify: true)
                default: break
                }
            }
            connection.start(queue: self.queue)
        }
        listener.start(queue: queue)
        socket.resume()
    }

    func close() { queue.async { self.finish(notify: false) } }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        queue.async {
            self.opened = true
            self.pumpIfReady()
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        queue.async { self.finish(notify: true) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        queue.async { self.finish(notify: true) }
    }

    private func pumpIfReady() {
        guard opened, peerReady, !pumping, !stopped else { return }
        pumping = true
        sendToRelay()
        readFromRelay()
    }

    private func sendToRelay() {
        guard !stopped, let peer = peer else { return }
        peer.receive(minimumIncompleteLength: 1, maximumLength: 32768) { [weak self] data, _, end, error in
            guard let self = self, !self.stopped else { return }
            guard let data = data, !data.isEmpty, let socket = self.socket, error == nil else {
                self.finish(notify: true)
                return
            }
            socket.send(.data(data)) { [weak self] error in
                self?.queue.async { [weak self] in
                    guard let self = self else { return }
                    if error == nil && !end { self.sendToRelay() }
                    else { self.finish(notify: true) }
                }
            }
        }
    }

    private func readFromRelay() {
        guard !stopped, let socket = socket else { return }
        socket.receive { [weak self] result in
            self?.queue.async { [weak self] in
                guard let self = self, !self.stopped, let peer = self.peer else { return }
                guard case let .success(.data(bytes)) = result, !bytes.isEmpty, bytes.count <= 65536 else {
                    self.finish(notify: true)
                    return
                }
                peer.send(content: bytes, completion: .contentProcessed { [weak self] error in
                    guard let self = self else { return }
                    if error == nil { self.readFromRelay() }
                    else { self.finish(notify: true) }
                })
            }
        }
    }

    private func finish(notify: Bool) {
        guard !stopped else { return }
        stopped = true
        listener?.cancel()
        peer?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
        listener = nil
        peer = nil
        socket = nil
        session = nil
        let callback = onFailure
        onFailure = nil
        onEndpoint = nil
        if notify, let callback = callback { DispatchQueue.main.async { callback() } }
    }
}
