import AppKit
import Carbon.HIToolbox

struct ScrollMotion: Codable {
    let horizontal: Double
    let vertical: Double
    let coarseHorizontal: Double
    let coarseVertical: Double
    let continuous: Bool
    let invertedFromDevice: Bool

    init(horizontal: Double, vertical: Double, coarseHorizontal: Double, coarseVertical: Double,
         continuous: Bool, invertedFromDevice: Bool) {
        self.horizontal = horizontal
        self.vertical = vertical
        self.coarseHorizontal = coarseHorizontal
        self.coarseVertical = coarseVertical
        self.continuous = continuous
        self.invertedFromDevice = invertedFromDevice
    }

    init?(_ event: NSEvent) {
        guard event.type == .scrollWheel else { return nil }
        let values = [event.scrollingDeltaX, event.scrollingDeltaY, event.deltaX, event.deltaY]
        guard values.allSatisfy(\.isFinite) else { return nil }
        let limit = event.hasPreciseScrollingDeltas ? 1200.0 : 64.0
        func bound(_ value: Double, _ limit: Double) -> Double { max(-limit, min(limit, value)) }
        self.init(horizontal: bound(event.scrollingDeltaX, limit), vertical: bound(event.scrollingDeltaY, limit),
                  coarseHorizontal: bound(event.deltaX, 1200), coarseVertical: bound(event.deltaY, 1200),
                  continuous: event.hasPreciseScrollingDeltas, invertedFromDevice: event.isDirectionInvertedFromDevice)
    }

    var valid: Bool {
        let limit = continuous ? 1200.0 : 64.0
        return [horizontal, vertical].allSatisfy { $0.isFinite && abs($0) <= limit } &&
            [coarseHorizontal, coarseVertical].allSatisfy { $0.isFinite && abs($0) <= 1200 }
    }

    static func phases(for event: NSEvent) -> (Int64, Int64) {
        if let cg = event.cgEvent {
            return (cg.getIntegerValueField(.scrollWheelEventScrollPhase),
                    cg.getIntegerValueField(.scrollWheelEventMomentumPhase))
        }
        let phase: Int64
        switch event.phase {
        case .mayBegin: phase = 128
        case .began: phase = 1
        case .changed, .stationary: phase = 2
        case .ended: phase = 4
        case .cancelled: phase = 8
        default: phase = 0
        }
        let momentum: Int64
        switch event.momentumPhase {
        case .began: momentum = 1
        case .changed, .stationary: momentum = 2
        case .ended, .cancelled: momentum = 3
        default: momentum = 0
        }
        return (phase, momentum)
    }
}

struct SessionScroll {
    private var residueX: Double = 0
    private var residueY: Double = 0
    private var continuous: Bool?
    private var invertedFromDevice: Bool?
    private var fingersMoving = false
    private var momentumMoving = false

    mutating func makeEvent(_ motion: ScrollMotion, phase: Int64?, momentum: Int64?,
                            source: CGEventSource?) -> CGEvent? {
        guard motion.valid else { return nil }
        let phase = phase.flatMap { [0, 1, 2, 4, 8, 128].contains($0) ? $0 : nil } ?? 0
        let momentum = momentum.flatMap { (0...3).contains($0) ? $0 : nil } ?? 0
        if continuous != motion.continuous || invertedFromDevice != motion.invertedFromDevice || phase == 1 || phase == 128 {
            residueX = 0
            residueY = 0
        }
        continuous = motion.continuous
        invertedFromDevice = motion.invertedFromDevice

        // The receiver's AppKit event already contains the user's chosen direction.
        // Carry fractional motion forward until the Quartz integer point field can represent it.
        let x = Self.takeWhole(motion.horizontal, residue: &residueX)
        let y = Self.takeWhole(motion.vertical, residue: &residueY)
        guard x != 0 || y != 0 || phase != 0 || momentum != 0 else { return nil }
        let event = CGEvent(scrollWheelEvent2Source: source, units: motion.continuous ? .pixel : .line,
                            wheelCount: 2, wheel1: y, wheel2: x, wheel3: 0)
        if motion.continuous {
            event?.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: motion.coarseVertical)
            event?.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: motion.coarseHorizontal)
        }
        event?.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        event?.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        if [1, 2, 128].contains(phase) { fingersMoving = true }
        if phase == 4 || phase == 8 { fingersMoving = false }
        if momentum == 1 || momentum == 2 { momentumMoving = true }
        if momentum == 3 { momentumMoving = false }
        return event
    }

    mutating func end(source: CGEventSource?) -> CGEvent? {
        let phase: Int64 = fingersMoving ? 8 : 0
        let momentum: Int64 = momentumMoving ? 3 : 0
        self = SessionScroll()
        guard phase != 0 || momentum != 0 else { return nil }
        let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                            wheel1: 0, wheel2: 0, wheel3: 0)
        event?.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        event?.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        return event
    }

    private static func takeWhole(_ delta: Double, residue: inout Double) -> Int32 {
        residue += delta
        let whole = Int32(residue.rounded(.towardZero))
        residue -= Double(whole)
        return whole
    }
}

struct MacModifierKey {
    let key: UInt16
    let flag: NSEvent.ModifierFlags
    let sideMask: UInt64
    let familyMask: UInt64

    // The side-specific bits are the device key masks published in IOKit's IOLLEvent.h.
    static let keys: [Self] = [
        .init(key: UInt16(kVK_Shift), flag: .shift, sideMask: 0x02, familyMask: 0x06),
        .init(key: UInt16(kVK_RightShift), flag: .shift, sideMask: 0x04, familyMask: 0x06),
        .init(key: UInt16(kVK_Control), flag: .control, sideMask: 0x01, familyMask: 0x2001),
        .init(key: UInt16(kVK_RightControl), flag: .control, sideMask: 0x2000, familyMask: 0x2001),
        .init(key: UInt16(kVK_Option), flag: .option, sideMask: 0x20, familyMask: 0x60),
        .init(key: UInt16(kVK_RightOption), flag: .option, sideMask: 0x40, familyMask: 0x60),
        .init(key: UInt16(kVK_Command), flag: .command, sideMask: 0x08, familyMask: 0x18),
        .init(key: UInt16(kVK_RightCommand), flag: .command, sideMask: 0x10, familyMask: 0x18),
        .init(key: UInt16(kVK_Function), flag: .function, sideMask: 0, familyMask: 0),
        .init(key: UInt16(kVK_CapsLock), flag: .capsLock, sideMask: 0, familyMask: 0),
    ]
    static let supportedFlags: UInt64 = keys.reduce(0x00ff0000) { $0 | $1.sideMask }

    static func matching(_ key: UInt16) -> Self? { keys.first { $0.key == key } }
}

final class MacModifierState {
    private static let shortcutGroups = [NSEvent.ModifierFlags.command, .shift, .option, .control].map { flag in
        MacModifierKey.keys.filter { $0.flag == flag }
    }
    private static let shortcutMask = shortcutGroups.joined().reduce(UInt64(0)) {
        $0 | $1.sideMask | UInt64($1.flag.rawValue)
    }

    private var held = Set<UInt16>()
    private var lastCapsPress: TimeInterval?

    func clear() {
        held.removeAll()
        lastCapsPress = nil
    }

    func shouldSwitchLanguage(_ event: NSEvent) -> Bool {
        guard event.type == .flagsChanged || (event.type == .keyDown && !event.isARepeat),
              lastCapsPress.map({ event.timestamp - $0 > 0.15 }) ?? true else { return false }
        lastCapsPress = event.timestamp
        return true
    }

    // A key event carries the modifier state even if a separate press or release was missed.
    func synchronize(flags: NSEvent.ModifierFlags, send: (UInt16, Bool, UInt64) -> Void) -> UInt64 {
        let raw = UInt64(flags.rawValue) & MacModifierKey.supportedFlags
        func resolvedFlags() -> UInt64 {
            Self.shortcutGroups.joined().reduce(raw & ~Self.shortcutMask) { result, modifier in
                guard held.contains(modifier.key) else { return result }
                return result | modifier.sideMask | UInt64(modifier.flag.rawValue)
            }
        }
        for group in Self.shortcutGroups {
            guard let first = group.first else { continue }
            let current = group.filter { held.contains($0.key) }
            let wanted: [MacModifierKey]
            if !flags.contains(first.flag) {
                wanted = []
            } else if raw & first.familyMask != 0 {
                wanted = group.filter { raw & $0.sideMask != 0 }
            } else {
                wanted = current.isEmpty ? [first] : current
            }
            let wantedKeys = Set(wanted.map(\.key))
            for modifier in current where !wantedKeys.contains(modifier.key) {
                held.remove(modifier.key)
                send(modifier.key, false, resolvedFlags())
            }
            for modifier in wanted where held.insert(modifier.key).inserted {
                send(modifier.key, true, resolvedFlags())
            }
        }
        return resolvedFlags()
    }

    func update(key: UInt16, flags: NSEvent.ModifierFlags) -> Bool? {
        guard let modifier = MacModifierKey.matching(key) else { return nil }
        if modifier.flag == .capsLock { return flags.contains(.capsLock) }
        let wasHeld = held.contains(key)
        let raw = UInt64(flags.rawValue)
        let down: Bool
        if !flags.contains(modifier.flag) {
            down = false
        } else if raw & modifier.familyMask != 0 {
            down = raw & modifier.sideMask != 0
        } else {
            // Some receivers deliver only the family bit. A matching event while the
            // other side remains held can still be a release of this side.
            let otherHeld = MacModifierKey.keys.contains { $0.key != key && $0.flag == modifier.flag && held.contains($0.key) }
            down = !wasHeld || !otherHeld
        }
        guard down != wasHeld else { return nil }
        if down { held.insert(key) }
        else { held.remove(key) }
        return down
    }
}

enum KeyboardLayoutResult: String, Codable {
    case matched
    case senderKept
}

enum MacInputSource {
    static func currentID() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        return identifier(source)
    }

    static func validID(_ id: String) -> Bool {
        let bytes = id.utf8
        return (1...180).contains(bytes.count) && bytes.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0)
        }
    }

    static var usesSystemCapsSwitch: Bool {
        UserDefaults.standard.bool(forKey: "AppleCapsLockSwitchesLanguage") ||
            UserDefaults(suiteName: "com.apple.HIToolbox")?.bool(forKey: "AppleCapsLockSwitchesLanguage") == true
    }

    static func koreanPair() -> (korean: String, english: String)? {
        let filter = [kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String] as CFDictionary
        guard let sources = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] else { return nil }
        var korean: [String] = []
        var english: [String] = []
        for source in sources {
            guard propertyIsTrue(source, kTISPropertyInputSourceIsSelectCapable),
                  let id = identifier(source),
                  let value = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages),
                  let languages = Unmanaged<CFArray>.fromOpaque(value).takeUnretainedValue() as? [String] else { continue }
            if languages.contains(where: { $0 == "ko" || $0.hasPrefix("ko-") }) { korean.append(id) }
            if propertyIsTrue(source, kTISPropertyInputSourceIsASCIICapable),
               languages.contains(where: { $0 == "en" || $0.hasPrefix("en-") }) { english.append(id) }
        }
        let current = currentID()
        let ascii = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue()
        let lastEnglish = ascii.flatMap(identifier)
        let defaultKorean = "com.apple.inputmethod.Korean.2SetKorean"
        guard let ko = current.flatMap({ korean.contains($0) ? $0 : nil }) ??
                  (korean.contains(defaultKorean) ? defaultKorean : korean.first),
              let en = current.flatMap({ english.contains($0) ? $0 : nil }) ??
                  lastEnglish.flatMap({ english.contains($0) ? $0 : nil }) ?? english.first else { return nil }
        return (ko, en)
    }

    static func selectable(_ id: String) -> TISInputSource? {
        guard validID(id) else { return nil }
        let filter = [kTISPropertyInputSourceID as String: id,
                      kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String] as CFDictionary
        let sources = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource]
        return sources?.first { propertyIsTrue($0, kTISPropertyInputSourceIsSelectCapable) }
    }

    private static func propertyIsTrue(_ source: TISInputSource, _ property: CFString) -> Bool {
        guard let flag = TISGetInputSourceProperty(source, property) else { return false }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(flag).takeUnretainedValue())
    }

    private static func identifier(_ source: TISInputSource) -> String? {
        guard let value = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(value).takeUnretainedValue() as String
    }
}

final class SessionKeyboardLayout {
    private struct Change: Codable {
        let original: String
        let selected: String
        let ownerPID: Int32
    }

    private static var journal: URL { LocalSetup.home.appendingPathComponent("keyboard-layout-session.json") }
    private var change: Change?

    static func recover() {
        guard let raw = try? Data(contentsOf: journal), raw.count <= 1024,
              let previous = try? JSONDecoder().decode(Change.self, from: raw), previous.ownerPID > 1,
              MacInputSource.validID(previous.original), MacInputSource.validID(previous.selected) else { return }
        let currentPID = ProcessInfo.processInfo.processIdentifier
        if previous.ownerPID != currentPID {
            guard kill(previous.ownerPID, 0) == -1, errno == ESRCH else { return }
        }
        _ = restore(previous)
    }

    func match(_ id: String) -> KeyboardLayoutResult {
        guard MacInputSource.validID(id), let current = MacInputSource.currentID() else { return .senderKept }
        if let previous = change, current != previous.selected {
            // A local user or an app already selected a different source.
            guard Self.restore(previous) else { return .senderKept }
            change = nil
        }
        guard current != id else { return .matched }
        if change == nil && FileManager.default.fileExists(atPath: Self.journal.path) {
            return .senderKept
        }
        guard let target = MacInputSource.selectable(id) else {
            finish()
            return .senderKept
        }
        let original = change?.original ?? current
        guard MacInputSource.selectable(original) != nil else { return .senderKept }
        let previous = change
        let next = Change(original: original, selected: id, ownerPID: ProcessInfo.processInfo.processIdentifier)
        do {
            try Self.save(next)
        } catch { return .senderKept }
        if TISSelectInputSource(target) == noErr {
            change = next
            return .matched
        }
        if let previous = previous { try? Self.save(previous) }
        else { try? FileManager.default.removeItem(at: Self.journal) }
        return .senderKept
    }

    func finish() {
        if let previous = change, Self.restore(previous) { change = nil }
    }

    private static func save(_ change: Change) throws {
        try LocalSetup.prepare()
        try JSONEncoder().encode(change).write(to: journal, options: .atomic)
    }

    private static func restore(_ change: Change) -> Bool {
        guard let current = MacInputSource.currentID() else { return false }
        if current == change.selected && current != change.original {
            guard let original = MacInputSource.selectable(change.original),
                  TISSelectInputSource(original) == noErr else { return false }
        }
        do {
            try FileManager.default.removeItem(at: journal)
            return true
        } catch let error as CocoaError {
            return error.code == .fileNoSuchFile
        } catch {
            return false
        }
    }
}
