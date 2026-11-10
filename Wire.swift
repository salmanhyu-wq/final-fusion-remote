import AppKit
import Network
import Security

let directProtocol = "studio-direct-1"
let nativePixelsProtocol = "studio-direct-2"

enum Kind: UInt8 {
    case hello = 1, screens, format, video, input, keepAlive, failure, pairing, diagnostics, receiverUpdate, videoFeedback, receiverControl
    case directOffer, directChoice, directTicket
    /// Host cursor shape (CursorShape). Sent only to receivers that opted in with Input.Action.cursorShapes.
    case cursor
}

struct DisplayInfo: Codable {
    let id: UInt32
    let name: String
    let width: Int
    let height: Int
    var receiverDiagnostics: Bool? = nil
    var localCursor: Bool? = nil
    var followsReceiver: Bool? = nil
    var macInputMatching: Bool? = nil
    var receiverUpdates: Bool? = nil
    var koreanCaps: Bool? = nil
    var logicalWidth: Int? = nil
    var logicalHeight: Int? = nil
    var advancedTrackpad: Bool? = nil
    var notificationShortcut: Bool? = nil
    var videoFeedback: Bool? = nil
    var clipboardScreenshots: Bool? = nil
    var nativePixels: Bool? = nil
    /// The host can send its cursor shape; receivers opt in with Input.Action.cursorShapes.
    var cursorShapes: Bool? = nil
}

struct ReceiverDisplayOptions {
    let width: Int
    let height: Int
    let matchDisplay: Bool
    let localCursor: Bool

    init?(width: Int, height: Int, matchDisplay: Bool, localCursor: Bool) {
        guard (640...8192).contains(width), (480...8192).contains(height) else { return nil }
        self.width = width
        self.height = height
        self.matchDisplay = matchDisplay
        self.localCursor = localCursor
    }

    init?(_ bytes: Data) {
        guard bytes.count == 5 else { return nil }
        let values = Array(bytes)
        guard (1...3).contains(values[0]) else { return nil }
        self.init(width: Int(values[1]) * 256 + Int(values[2]), height: Int(values[3]) * 256 + Int(values[4]),
                  matchDisplay: values[0] & 2 != 0, localCursor: values[0] & 1 != 0)
    }

    var bytes: Data {
        Data([(localCursor ? 1 : 0) | (matchDisplay ? 2 : 0),
              UInt8(width >> 8), UInt8(truncatingIfNeeded: width),
              UInt8(height >> 8), UInt8(truncatingIfNeeded: height)])
    }

    func hasMatchingAspect(width otherWidth: Int, height otherHeight: Int) -> Bool {
        guard otherWidth > 0, otherHeight > 0 else { return false }
        let ratio = Double(width) / Double(height)
        let candidate = Double(otherWidth) / Double(otherHeight)
        return abs(candidate / ratio - 1) < 0.005
    }
}

struct ReceiverNativePixels: Equatable {
    let width: Int
    let height: Int

    init?(width: Int, height: Int) {
        guard (640...4096).contains(width), (480...4096).contains(height),
              width.isMultiple(of: 2), height.isMultiple(of: 2), width * height <= 4096 * 2160 else { return nil }
        self.width = width
        self.height = height
    }

    init?(_ bytes: Data) {
        guard bytes.count == 4 else { return nil }
        let values = Array(bytes)
        self.init(width: Int(values[0]) * 256 + Int(values[1]), height: Int(values[2]) * 256 + Int(values[3]))
    }

    var bytes: Data {
        Data([UInt8(width >> 8), UInt8(truncatingIfNeeded: width),
              UInt8(height >> 8), UInt8(truncatingIfNeeded: height)])
    }

    var size: CGSize { CGSize(width: width, height: height) }

    func fitsSource(width: Int, height: Int) -> Bool {
        guard width >= self.width, height >= self.height else { return false }
        return abs(Double(width) * Double(self.height) / (Double(height) * Double(self.width)) - 1) < 0.005
    }
}

enum ReceiverResolution: Int, Codable, CaseIterable {
    case low, medium, high, native

    var title: String {
        switch self {
        case .low: return L("낮음", "Low")
        case .medium: return L("중간", "Medium")
        case .high: return L("높음", "High")
        case .native: return L("원본 화질 (바로 연결)", "Full quality (direct)")
        }
    }

    func displayOptions(width: Int, height: Int) -> ReceiverDisplayOptions? {
        guard (640...8192).contains(width), (480...8192).contains(height) else { return nil }
        var divisor = width, remainder = height
        while remainder != 0 { (divisor, remainder) = (remainder, divisor % remainder) }
        let unitWidth = width / divisor, unitHeight = height / divisor
        let scale = [16, 18, 21, 21][rawValue]
        let multiplier = min((divisor * scale + 8) / 16, 8192 / max(unitWidth, unitHeight))
        return ReceiverDisplayOptions(width: unitWidth * multiplier, height: unitHeight * multiplier,
                                      matchDisplay: true, localCursor: true)
    }
}

struct VideoFeedback {
    let receivedBytes: UInt64
    let requestKeyframe: Bool

    init(receivedBytes: UInt64, requestKeyframe: Bool) {
        self.receivedBytes = receivedBytes
        self.requestKeyframe = requestKeyframe
    }

    init?(_ data: Data) {
        guard data.count == 9, let flag = data.last, flag <= 1 else { return nil }
        receivedBytes = UInt64(data.number(at: 0)) << 32 | UInt64(data.number(at: 4))
        requestKeyframe = flag == 1
    }

    var bytes: Data {
        var data = Data()
        data.put(UInt32(truncatingIfNeeded: receivedBytes >> 32))
        data.put(UInt32(truncatingIfNeeded: receivedBytes))
        data.append(requestKeyframe ? 1 : 0)
        return data
    }
}

// Local socket writes can finish while the internet relay is still buffering video.
// Account for bytes until the receiver actually reads them. Allow the path's
// bandwidth-delay product plus a small margin so high base RTT needn't cap FPS.
struct VideoSendWindow {
    private(set) var enabled = false
    private(set) var acknowledged: UInt64 = 0
    private var sent: UInt64 = 0
    private var history: [(through: UInt64, atMS: UInt64)] = []
    private var minimums: [(second: UInt64, delayMS: Int)] = []
    private var smoothedQueueDelay: Int?
    var outstanding: UInt64 { sent - acknowledged }
    var baseRoundTripMS: Int? { minimums.map(\.delayMS).min() }

    func hasRoom(bitrate: Int) -> Bool {
        guard enabled else { return true }
        let roundTrip = min(450, max(10, baseRoundTripMS ?? 120))
        // A congested path must not grow a large queue of video that TCP still has to deliver.
        let budget = min(192 * 1024, max(48 * 1024, bitrate * (roundTrip + 40) / 8_000))
        return outstanding < UInt64(budget)
    }

    func queueDelayWhileWaiting(atMS now: UInt64) -> Int? {
        guard enabled, let baseline = baseRoundTripMS,
              let oldest = history.first, now >= oldest.atMS else { return nil }
        return max(0, Int(clamping: now - oldest.atMS) - baseline)
    }

    mutating func record(_ bytes: Int, atMS now: UInt64) {
        sent += UInt64(bytes)
        history.append((sent, now))
        if history.count > 192 { history.removeFirst(history.count - 192) }
    }

    // nil means invalid; a valid ACK can have no latency sample (e.g. opt-in).
    mutating func acknowledge(_ total: UInt64, atMS now: UInt64) -> (queueDelayMS: Int?, progressed: Bool)? {
        guard total >= acknowledged, total <= sent else { return nil }
        enabled = true
        guard total > acknowledged else { return (nil, false) }
        acknowledged = total
        let stamp = history.last { $0.through == total }?.atMS
        if let consumed = history.firstIndex(where: { $0.through > total }) {
            history.removeFirst(consumed)
        } else {
            history.removeAll(keepingCapacity: true)
        }
        guard let stamp = stamp, stamp <= now, now - stamp <= 10_000 else { return (nil, true) }
        let second = now / 1_000
        minimums.removeAll { second - $0.second >= 24 }
        let delay = Int(now - stamp)
        if minimums.last?.second == second {
            minimums[minimums.count - 1].delayMS = min(minimums[minimums.count - 1].delayMS, delay)
        } else {
            if minimums.isEmpty { smoothedQueueDelay = nil }
            minimums.append((second, delay))
        }
        let extra = delay - (baseRoundTripMS ?? delay)
        let filtered = ((smoothedQueueDelay ?? extra) * 3 + extra + 2) / 4
        smoothedQueueDelay = filtered
        return (filtered, true)
    }
}

struct Input: Codable {
    enum Action: String, Codable {
        case keyDown, keyUp, flags, move, down, up, scroll, gesture, release, spacePrevious, spaceNext
        case inputSource, koreanCaps, missionControl, appWindows, zoomIn, zoomOut
        case screenshotFull, screenshotArea, screenshotOptions
        case launchApps, showDesktop, lookup, notificationCenter, pagePrevious, pageNext
        case rotateLeft, rotateRight, smartZoom
        /// Receiver opt-in for cursor shape messages. Older hosts fail to decode it and ignore it.
        case cursorShapes
    }

    let action: Action
    var display: UInt32 = 0
    var x: Double = 0
    var y: Double = 0
    var a: Int = 0
    var b: Int = 0
    var flags: UInt64 = 0
    var repeatKey: Bool?
    var sequence: UInt64?
    var pressure: Double?
    var scrollPhase: Int64?
    var momentumPhase: Int64?
    var gestureData: Data?
    var scrollMotion: ScrollMotion?
    var keyboardType: Int64?
    var keyboardInputSource: String?
    var screenshotRegion: ScreenshotRegion?
}

struct ScreenshotRegion: Codable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(first: CGPoint, last: CGPoint) {
        x = Double(min(first.x, last.x))
        y = Double(min(first.y, last.y))
        width = Double(abs(first.x - last.x))
        height = Double(abs(first.y - last.y))
    }

    func pixels(in size: CGSize) -> CGRect? {
        guard [x, y, width, height].allSatisfy(\.isFinite), x >= 0, y >= 0, width > 0, height > 0,
              x + width <= 1.000001, y + height <= 1.000001, size.width >= 2, size.height >= 2 else { return nil }
        let crop = CGRect(x: x * size.width, y: y * size.height, width: width * size.width, height: height * size.height)
            .integral.intersection(CGRect(origin: .zero, size: size))
        return crop.width >= 2 && crop.height >= 2 ? crop : nil
    }
}

func isRemoteGesture(_ type: NSEvent.EventType) -> Bool {
    switch type {
    case .magnify, .rotate, .swipe, .smartMagnify, .beginGesture, .endGesture, .pressure: return true
    default: return false
    }
}

enum StudioError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case let .message(value): return value }
    }
}

extension Data {
    mutating func put(_ number: UInt32) {
        var value = number.bigEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }

    func number(at offset: Int) -> UInt32 {
        dropFirst(offset).prefix(4).reduce(0) { ($0 << 8) | UInt32($1) }
    }
}

func makeCode() throws -> Data {
    var bytes = [UInt8](repeating: 0, count: 16)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
        throw StudioError.message(L("접속 코드를 만들 수 없어요.", "Couldn't create an access code."))
    }
    return Data(bytes)
}

func hex(_ bytes: Data) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
}

func decodeCode(_ input: String) -> Data? {
    let bytes = Array(input.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
    guard bytes.count == 32 else { return nil }
    var result = Data()
    for index in stride(from: 0, to: bytes.count, by: 2) {
        guard let value = UInt8(String(decoding: bytes[index...index+1], as: UTF8.self), radix: 16),
              bytes[index] != 43 else { return nil }
        result.append(value)
    }
    return result
}

func matches(_ a: Data, _ b: Data) -> Bool {
    guard a.count == b.count else { return false }
    return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
}

func tcpParameters() -> NWParameters {
    let tcp = NWProtocolTCP.Options()
    tcp.noDelay = true
    let parameters = NWParameters(tls: nil, tcp: tcp)
    return parameters
}

func loopback(_ port: UInt16) -> NWEndpoint {
    .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
}

final class Wire {
    static let maxFrame = 4 * 1024 * 1024
    private let connection: NWConnection?
    private let processInput: FileHandle?
    private let processOutput: FileHandle?
    private let reader = DispatchQueue(label: "studio-remote.ssh-read")
    private let writer = DispatchQueue(label: "studio-remote.ssh-write")
    let queue: DispatchQueue
    private var ended = false
    private let budgetLock = NSLock()
    private var pending = 0

    var onReady: (() -> Void)?
    var onMessage: ((Kind, UInt32, Data) -> Void)?
    var onEnd: ((String) -> Void)?

    init(_ connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        processInput = nil
        processOutput = nil
        self.queue = queue
    }

    init(processInput: FileHandle, processOutput: FileHandle, queue: DispatchQueue) {
        connection = nil
        self.processInput = processInput
        self.processOutput = processOutput
        self.queue = queue
    }

    private var negotiatedProtocol: String? {
        guard let metadata = connection?.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata,
              let name = sec_protocol_metadata_get_negotiated_protocol(metadata.securityProtocolMetadata) else { return nil }
        return String(cString: name)
    }

    var supportsNativePixels: Bool { negotiatedProtocol == nativePixelsProtocol }

    var supportsDirect: Bool {
        guard let name = negotiatedProtocol else { return false }
        return name == directProtocol || name == nativePixelsProtocol
    }

    func start() {
        guard let connection = connection else {
            onReady?()
            readHeader()
            return
        }
        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.onReady?()
                self.readHeader()
            case let .failed(error): self.end(error.localizedDescription)
            case .cancelled: self.end(L("연결을 끝냈어요.", "Disconnected."))
            default: break
            }
        }
        connection.start(queue: queue)
    }

    func close(_ reason: String = L("연결을 끝냈어요.", "Disconnected.")) {
        queue.async { self.end(reason) }
    }

    func hasVideoRoom(maxPending: Int = 192 * 1024) -> Bool {
        budgetLock.lock()
        defer { budgetLock.unlock() }
        return pending < maxPending
    }

    @discardableResult
    func send(_ kind: Kind, screen: UInt32 = 0, data: Data = Data()) -> Bool {
        let limit = kind == .video ? Self.maxFrame : (kind == .format ? 8192 : 32768)
        guard data.count <= limit else { return false }
        var frame = Data([kind.rawValue])
        frame.put(screen)
        frame.put(UInt32(data.count))
        frame.append(data)
        budgetLock.lock()
        let frameSize = frame.count
        if pending + frameSize > Self.maxFrame + 1024 * 1024 {
            budgetLock.unlock()
            return false
        }
        pending += frameSize
        budgetLock.unlock()
        let completed: (Error?) -> Void = { [weak self] error in
            guard let self = self else { return }
            self.budgetLock.lock()
            self.pending -= frameSize
            self.budgetLock.unlock()
            if let error = error { self.end(error.localizedDescription) }
        }
        if let connection = connection {
            connection.send(content: frame, completion: .contentProcessed { completed($0) })
        } else if let processInput = processInput {
            let payload = frame
            writer.async {
                do {
                    try processInput.write(contentsOf: payload)
                    self.queue.async { completed(nil) }
                } catch {
                    self.queue.async { completed(error) }
                }
            }
        }
        return true
    }

    private func readHeader() {
        receive(9) { [weak self] header in
            guard let self = self, let first = header.first, let kind = Kind(rawValue: first) else {
                self?.end(L("화면 데이터를 읽지 못했어요.", "Couldn't read the screen data."))
                return
            }
            let id = header.number(at: 1)
            let length = Int(header.number(at: 5))
            let limit = kind == .video ? Self.maxFrame : (kind == .format ? 8192 : 32768)
            guard length <= limit else { self.end(L("화면 데이터가 너무 커서 연결을 끝냈어요.", "Screen data was too large, so the connection closed.")); return }
            if length == 0 {
                self.onMessage?(kind, id, Data())
                self.readHeader()
            } else {
                self.receive(length) { [weak self] data in
                    guard let self = self else { return }
                    self.onMessage?(kind, id, data)
                    self.readHeader()
                }
            }
        }
    }

    private func receive(_ length: Int, then: @escaping (Data) -> Void) {
        guard !ended else { return }
        if let processOutput = processOutput {
            reader.async {
                do {
                    var buffer = Data()
                    while buffer.count < length {
                        guard let part = try processOutput.read(upToCount: length - buffer.count), !part.isEmpty else {
                            throw StudioError.message(L("연결 통로가 닫혔어요.", "The connection closed."))
                        }
                        buffer.append(part)
                    }
                    let message = buffer
                    self.queue.async { if !self.ended { then(message) } }
                } catch {
                    self.queue.async { self.end(error.localizedDescription) }
                }
            }
            return
        }
        receiveTCP(length, accumulated: Data(), then: then)
    }

    private func receiveTCP(_ length: Int, accumulated: Data, then: @escaping (Data) -> Void) {
        let remaining = length - accumulated.count
        connection?.receive(minimumIncompleteLength: 1, maximumLength: min(remaining, 64 * 1024)) { [weak self] data, _, _, error in
            guard let self = self, !self.ended else { return }
            if let error = error { self.end(error.localizedDescription); return }
            guard let data = data, !data.isEmpty else { self.end(L("상대 기기가 연결을 끝냈어요.", "The other device disconnected.")); return }
            var buffer = accumulated
            buffer.append(data)
            if buffer.count == length { then(buffer) }
            else { self.receiveTCP(length, accumulated: buffer, then: then) }
        }
    }

    private func end(_ reason: String) {
        guard !ended else { return }
        ended = true
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        let callback = onEnd
        onReady = nil
        onMessage = nil
        onEnd = nil
        callback?(reason)
    }
}


struct ReceiverDisplayDiagnostics: Codable {
    let id: UInt32
    let localWidth: Int
    let localHeight: Int
    let fillsScreen: Bool
    let localCursorHidden: Bool
    let receivedFrames: Int
    let submittedFrames: Int
    let pinchEvents: Int
    let multiTouchEvents: Int
    let gestureShortcuts: Int
    let nativeGestureEvents: Int
    let nativeGestures: Int
    var scrollEvents: Int? = nil
    var naturalScrolling: Bool? = nil
    var visibleWidth: Int? = nil
    var visibleHeight: Int? = nil
    var trackpadCommands: [String: Int]? = nil

    var valid: Bool {
        (1...32768).contains(localWidth) && (1...32768).contains(localHeight) &&
        (0...5000).contains(receivedFrames) && (0...receivedFrames).contains(submittedFrames) &&
        [pinchEvents, multiTouchEvents, gestureShortcuts, nativeGestureEvents, nativeGestures, scrollEvents ?? 0]
            .allSatisfy { (0...1_000_000).contains($0) } &&
        (visibleWidth.map { (1...localWidth).contains($0) } ?? true) &&
        (visibleHeight.map { (1...localHeight).contains($0) } ?? true) &&
        (trackpadCommands.map { $0.count <= 20 && $0.allSatisfy {
            $0.key.utf8.count <= 32 && (0...1_000_000).contains($0.value)
        } } ?? true)
    }
}

struct ReceiverDiagnostics: Codable {
    let seconds: Int
    let displays: [ReceiverDisplayDiagnostics]
    var roundTripMS: Int? = nil
    var systemShortcuts: Bool? = nil
    var clientVersion: String? = nil
    var tuning: ReceiverTuningStatus? = nil
    var sentInputCount: UInt64? = nil
    var connectionPath: ConnectionPath? = nil

    var valid: Bool {
        (1...30).contains(seconds) && (1...8).contains(displays.count) &&
        Set(displays.map(\.id)).count == displays.count && displays.allSatisfy(\.valid) &&
        (roundTripMS.map { (0...10_000).contains($0) } ?? true) &&
        (clientVersion.map { ReceiverUpdateVersion($0) != nil } ?? true)
    }
}

enum ConnectionPath: String, Codable {
    case direct, relay
}

struct ReceiverTuningStatus: Codable {
    let session: UUID
    let resolution: ReceiverResolution
    let allowed: Bool
}

struct ReceiverResolutionRequest: Codable {
    let id: UUID
    let session: UUID
    let resolution: ReceiverResolution
    let issuedAt: Date

    func canSend(to target: ReceiverTuningStatus, now: Date) -> Bool {
        target.allowed && session == target.session && resolution != target.resolution &&
            (0...15).contains(now.timeIntervalSince(issuedAt))
    }
}

enum StreamMode: String, Codable, CaseIterable {
    case auto, smooth, sharp

    var title: String {
        switch self {
        case .auto: return L("자동", "Auto")
        case .smooth: return L("부드럽게", "Smooth")
        case .sharp: return L("선명하게", "Sharp")
        }
    }
}

enum StreamLoad: Int {
    case full, lighterVideo, lowerFPS, minimum, stalled, deepStall

    func frameRate(_ maximum: Int) -> Int {
        switch self {
        case .full, .lighterVideo: return maximum
        case .lowerFPS: return min(maximum, max(20, maximum * 2 / 3))
        case .minimum: return min(maximum, max(20, maximum / 2))
        case .stalled, .deepStall: return min(maximum, max(20, maximum / 3))
        }
    }

    func bitRate(_ maximum: Int) -> Int {
        maximum * [100, 68, 48, 34, 25, 15][rawValue] / 100
    }
}

struct StreamTuning {
    static let severeQueueDelayMS = 180

    private var mode: StreamMode = .auto
    private var network = StreamLoad.full
    private var congested = 0
    private var clear = 0
    private var decodeLimited = false
    private var decodingSlow = 0
    private var decodingWell = 0
    private var recentPings: [Int] = []

    var load: StreamLoad {
        switch mode {
        case .smooth: return .lowerFPS
        case .sharp: return .full
        case .auto:
            return decodeLimited && network.rawValue < StreamLoad.lowerFPS.rawValue ? .lowerFPS : network
        }
    }
    var reduced: Bool { load != .full }

    mutating func update(mode: StreamMode, sample: ReceiverDisplayDiagnostics? = nil, roundTripMS: Int? = nil) {
        if self.mode != mode {
            self = StreamTuning()
            self.mode = mode
        }
        guard mode == .auto else { return }
        // A still desktop does not produce 60 distinct pictures each second.
        if let sample = sample, sample.receivedFrames >= 12 {
            let percent = sample.submittedFrames * 100 / sample.receivedFrames
            decodingSlow = percent < 85 ? decodingSlow + 1 : 0
            decodingWell = percent >= 97 ? decodingWell + 1 : 0
            if decodingSlow >= 2 { decodeLimited = true; decodingSlow = 0 }
            if decodingWell >= 4 { decodeLimited = false; decodingWell = 0 }
        }
        // Older receivers don't send fast feedback; use their connection report.
        if let rtt = roundTripMS {
            recentPings.append(rtt)
            if recentPings.count > 8 { recentPings.removeFirst() }
            observeNetwork(extraDelayMS: rtt - (recentPings.min() ?? rtt), blocked: false)
        }
    }

    mutating func observeNetwork(extraDelayMS: Int, blocked: Bool) {
        guard mode == .auto else { return }
        if extraDelayMS >= Self.severeQueueDelayMS {
            let limit: StreamLoad
            switch extraDelayMS {
            case 750...: limit = .deepStall
            case 400...: limit = .stalled
            default: limit = .minimum
            }
            if network.rawValue < limit.rawValue { network = limit }
            congested = 0
            clear = 0
            return
        }

        congested = extraDelayMS >= 65 || blocked ? congested + 1 : 0
        clear = extraDelayMS < 30 && !blocked ? clear + 1 : 0
        if congested >= 2 {
            if network.rawValue < StreamLoad.minimum.rawValue {
                network = StreamLoad(rawValue: network.rawValue + 1) ?? .minimum
            }
            congested = 0
        }
        if clear >= 4 {
            network = StreamLoad(rawValue: network.rawValue - 1) ?? .full
            clear = 0
        }
    }
}

struct SenderStreamDiagnostics: Codable {
    let id: UInt32
    let targetFPS: Int
    let targetKbps: Int
    let reduced: Bool
    var pendingVideoBytes: UInt64? = nil
    var baseVideoRoundTripMS: Int? = nil
    var videoQueueDelayMS: Int? = nil
    var encodeMS: Double? = nil
}

struct ReceiverDiagnosticsSnapshot: Codable {
    let receivedAt: Date
    let mode: StreamMode
    let reducedDisplays: [UInt32]
    let senderDisplays: [DisplayInfo]
    let receiver: ReceiverDiagnostics
    var keyboardLayout: KeyboardLayoutResult? = nil
    var receiverAppVersion: String? = nil
    var senderStreams: [SenderStreamDiagnostics]? = nil
    var screenshotCopied: Bool? = nil
    var acceptedInputCount: UInt64? = nil
}
