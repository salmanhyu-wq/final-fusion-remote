import AppKit

struct TrackpadGestures {
    private struct Sample {
        let count: Int
        let center: CGPoint
        let radius: CGFloat

        init(_ positions: [CGPoint], aspect: CGFloat) {
            count = positions.count
            let center = CGPoint(x: positions.reduce(0) { $0 + $1.x } / CGFloat(count),
                                 y: positions.reduce(0) { $0 + $1.y } / CGFloat(count))
            self.center = center
            radius = sqrt(positions.reduce(0) {
                let x = $1.x - center.x, y = ($1.y - center.y) * aspect
                return $0 + x * x + y * y
            } / CGFloat(count))
        }
    }

    private var start: Sample?
    private var peak = 0
    private var began: TimeInterval?
    private var moved = false
    private var pairCenter: CGPoint?
    private var lastPairTap: (position: CGPoint, time: TimeInterval)?
    private(set) var consumed = false

    var isTracking: Bool { began != nil }
    var hasSeveralFingers: Bool { peak >= 3 }

    mutating func clearPairTap() { lastPairTap = nil }

    mutating func inhibitTap() {
        moved = true
        clearPairTap()
    }

    mutating func cancel() {
        consumed = true
        clearPairTap()
    }

    mutating func update(_ positions: [CGPoint], at time: TimeInterval, aspect: CGFloat,
                         allowLookup: Bool = true, allowEdge: Bool = false, allowSmartZoom: Bool = false) -> Input.Action? {
        if positions.isEmpty {
            guard let began = began else { consumed = false; return nil }
            let tapped = !consumed && !moved && (0...0.25).contains(time - began)
            let lookup = allowLookup && peak == 3 && tapped
            let pair = allowSmartZoom && peak == 2 && tapped ? pairCenter : nil
            let prior = lastPairTap
            self = TrackpadGestures()
            if lookup { return .lookup }
            if let pair = pair {
                if let prior = prior, (0.07...0.45).contains(time - prior.time),
                   hypot(pair.x - prior.position.x, pair.y - prior.position.y) <= 0.09 {
                    return .smartZoom
                }
                lastPairTap = (pair, time)
            }
            return nil
        }
        guard !consumed, positions.count <= 4, aspect.isFinite, aspect > 0 else { return nil }
        if began == nil { began = time }
        peak = max(peak, positions.count)
        let now = Sample(positions, aspect: aspect)
        if now.count == 2 { pairCenter = now.center }
        guard let origin = start, now.count == origin.count else {
            start = now
            return nil
        }
        let dx = now.center.x - origin.center.x
        let dy = now.center.y - origin.center.y
        let radial = now.radius - origin.radius
        if max(abs(dx), abs(dy), abs(radial)) >= 0.035 { moved = true }

        let action: Input.Action
        switch now.count {
        case 4 where abs(radial) >= max(0.045, origin.radius * 0.24) &&
                          abs(radial) >= hypot(dx, dy * aspect) * 0.85:
            action = radial < 0 ? .launchApps : .showDesktop
        case 3, 4:
            // A moving group is a swipe. A group changing size is a pinch/spread.
            guard abs(radial) < hypot(dx, dy * aspect) * 0.70 else { return nil }
            if abs(dy) >= 0.075 && abs(dy) * 0.80 >= abs(dx) {
                action = dy > 0 ? .missionControl : .appWindows
            } else if abs(dx) >= 0.11 && abs(dx) * 0.72 >= abs(dy) {
                action = dx < 0 ? .spaceNext : .spacePrevious
            } else { return nil }
        case 2 where allowEdge && peak == 2 && origin.center.x >= 0.90 && dx <= -0.19 &&
                          abs(dx) >= abs(dy) * 2 && abs(radial) <= 0.035:
            action = .notificationCenter
        default:
            return nil
        }
        consumed = true
        return action
    }
}

struct TrackpadPinch {
    private var initialDistance: CGFloat?
    private var initialCenter: CGPoint?
    private var lastStep: CGFloat?
    private var initialAngle: CGFloat = 0
    private var rotated = false

    mutating func update(_ positions: [CGPoint], allowRotation: Bool = false) -> Input.Action? {
        guard positions.count == 2 else { self = TrackpadPinch(); return nil }
        let first = positions[0]
        let second = positions[1]
        let dx = second.x - first.x, dy = second.y - first.y
        let distance = hypot(dx, dy)
        guard !rotated, distance.isFinite, distance >= 0.025 else { return nil }
        let angle = atan2(dy, dx)
        let center = CGPoint(x: (first.x + second.x) / 2, y: (first.y + second.y) / 2)
        guard let initialDistance = initialDistance, let initialCenter = initialCenter else {
            self.initialDistance = distance
            self.initialCenter = center
            initialAngle = angle
            return nil
        }
        if allowRotation && lastStep == nil, abs(distance / initialDistance - 1) <= 0.20,
           hypot(center.x - initialCenter.x, center.y - initialCenter.y) < 0.06 {
            let turn = (angle - initialAngle).remainder(dividingBy: .pi)
            if abs(turn) >= .pi / 5 {
                rotated = true
                return turn > 0 ? .rotateLeft : .rotateRight
            }
        }
        let previous = lastStep ?? initialDistance
        let change = distance - previous
        guard abs(change) >= max(0.026, previous * 0.16) else { return nil }
        if lastStep == nil {
            let translation = hypot(center.x - initialCenter.x, center.y - initialCenter.y)
            guard abs(change) > translation * 1.3 else { return nil }
        }
        lastStep = distance
        return change > 0 ? .zoomIn : .zoomOut
    }
}

// AppKit can cancel contacts claimed by system gestures. Read the built-in
// trackpad as a second source while a receiver session is open. This interface
// is optional because Apple does not publish a stable ABI for it.
final class BuiltInTrackpad {
    private typealias FrameCallback = @convention(c) (UnsafeRawPointer?, UnsafeRawPointer?, Int32, Double, Int32) -> Void
    private struct API {
        typealias CreateList = @convention(c) () -> Unmanaged<CFArray>?
        typealias IsBuiltIn = @convention(c) (UnsafeRawPointer) -> Bool
        typealias Register = @convention(c) (UnsafeRawPointer, FrameCallback) -> Void
        typealias Start = @convention(c) (UnsafeRawPointer, Int32) -> Int32
        typealias Stop = @convention(c) (UnsafeRawPointer) -> Int32

        let createList: CreateList
        let isBuiltIn: IsBuiltIn
        let register: Register
        let unregister: Register
        let start: Start
        let stop: Stop

        init?() {
            guard let library = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport",
                                       RTLD_LAZY | RTLD_LOCAL) else { return nil }
            guard let create = dlsym(library, "MTDeviceCreateList"),
                  let builtIn = dlsym(library, "MTDeviceIsBuiltIn"),
                  let register = dlsym(library, "MTRegisterContactFrameCallback"),
                  let unregister = dlsym(library, "MTUnregisterContactFrameCallback"),
                  let start = dlsym(library, "MTDeviceStart"),
                  let stop = dlsym(library, "MTDeviceStop") else {
                dlclose(library)
                return nil
            }
            createList = unsafeBitCast(create, to: CreateList.self)
            isBuiltIn = unsafeBitCast(builtIn, to: IsBuiltIn.self)
            self.register = unsafeBitCast(register, to: Register.self)
            self.unregister = unsafeBitCast(unregister, to: Register.self)
            self.start = unsafeBitCast(start, to: Start.self)
            self.stop = unsafeBitCast(stop, to: Stop.self)
        }
    }

    private static let api = API()
    private static let lock = NSLock()
    private static weak var listener: BuiltInTrackpad?
    private static let callback: FrameCallback = { device, frame, count, _, _ in
        guard (0...16).contains(count), let device = device else { return }
        BuiltInTrackpad.lock.lock()
        let listener = BuiltInTrackpad.listener
        BuiltInTrackpad.lock.unlock()
        guard let listener = listener, listener.device == device else { return }

        var points: [CGPoint] = []
        if let frame = frame, count >= 3 {
            // MultitouchSupport's 64-bit contact records have a 96-byte stride.
            // State is at byte 20 and the normalized position is at bytes 32/36.
            for index in 0..<Int(count) {
                let contact = frame.advanced(by: index * 96)
                let state = contact.load(fromByteOffset: 20, as: UInt32.self)
                guard state == 3 || state == 4 else { continue }
                let x = contact.load(fromByteOffset: 32, as: Float.self)
                let y = contact.load(fromByteOffset: 36, as: Float.self)
                guard (0...1).contains(x), (0...1).contains(y) else { continue }
                points.append(CGPoint(x: CGFloat(x), y: CGFloat(y)))
            }
        }
        BuiltInTrackpad.lock.lock()
        let group = points.count >= 3
        let shouldSend = BuiltInTrackpad.listener === listener && (group || listener.hadGroup)
        listener.hadGroup = group
        BuiltInTrackpad.lock.unlock()
        guard shouldSend else { return }
        let positions = group ? points : []
        let time = ProcessInfo.processInfo.systemUptime
        DispatchQueue.main.async { [weak listener] in
            guard let listener = listener, listener.running else { return }
            listener.onFrame(positions, time)
        }
    }

    private let devices: CFArray
    private let device: UnsafeRawPointer
    private var running = false
    private var hadGroup = false
    private let onFrame: ([CGPoint], TimeInterval) -> Void

    init?(onFrame: @escaping ([CGPoint], TimeInterval) -> Void) {
        guard let api = Self.api, let devices = api.createList()?.takeRetainedValue() else { return nil }
        let builtIn = (0..<CFArrayGetCount(devices)).lazy.compactMap { CFArrayGetValueAtIndex(devices, $0) }
            .first(where: api.isBuiltIn)
        guard let device = builtIn else { return nil }
        self.devices = devices
        self.device = device
        self.onFrame = onFrame

        Self.lock.lock()
        guard Self.listener == nil else { Self.lock.unlock(); return nil }
        Self.listener = self
        Self.lock.unlock()
        api.register(device, Self.callback)
        if api.start(device, 0) != 0 {
            api.unregister(device, Self.callback)
            Self.lock.lock()
            Self.listener = nil
            Self.lock.unlock()
            return nil
        }
        running = true
    }

    func stop() {
        guard running, let api = Self.api else { return }
        running = false
        Self.lock.lock()
        Self.listener = nil
        Self.lock.unlock()
        api.unregister(device, Self.callback)
        _ = api.stop(device)
    }

    deinit { stop() }
}
