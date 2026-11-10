import AppKit
import Carbon.HIToolbox
import ServiceManagement

final class ReceiverMode {
    private var windows: [ReceiverWindow] = []
    private var views: [RemoteView] = []
    private var notifications: [NSObjectProtocol] = []
    private var localMonitor: Any?
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var previousPresentation: NSApplication.PresentationOptions = []
    private var fnDown = false
    private var previousStatus = ""
    private var previousActivity: OperationActivity = .idle
    private var activity: NSObjectProtocol?
    private var builtInTrackpad: BuiltInTrackpad?
    private weak var trackpadView: RemoteView?
    private var trackpadSequence = false
    private(set) var isActive = false
    private var hotKeyToken: UnsafeMutableRawPointer?
    var handlesSystemShortcuts: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }
    var onExit: (() -> Void)?

    static let exitKeys = "Fn + Control + Option + Command + F12"

    static func isExitKey(_ key: UInt16, flags: NSEvent.ModifierFlags, fnDown: Bool) -> Bool {
        let modifiers: NSEvent.ModifierFlags = [.control, .option, .command, .shift]
        return key == UInt16(kVK_F12) && fnDown && flags.intersection(modifiers) == [.control, .option, .command]
    }

    func enter() {
        guard !isActive else { return }
        isActive = true
        previousPresentation = NSApp.presentationOptions
        NSApp.presentationOptions = [.hideDock, .hideMenuBar, .disableAppleMenu,
                                      .disableProcessSwitching, .disableForceQuit, .disableHideApplication]
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleDisplaySleepDisabled], reason: "Studio Receiver fullscreen")
        let center = NotificationCenter.default
        notifications = [
            center.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                               object: nil, queue: .main) { [weak self] _ in self?.layout() },
            center.addObserver(forName: NSApplication.didResignActiveNotification,
                               object: nil, queue: .main) { [weak self] _ in
                guard let self = self, self.isActive else { return }
                self.trackpadView?.cancelBuiltInTrackpadGesture()
                self.trackpadView = nil
                self.activeView?.releaseInput()
                self.fnDown = false
                DispatchQueue.main.async { [weak self] in self?.bringForward() }
            }
        ]
        let keyboard: NSEvent.EventTypeMask = [.keyDown, .keyUp, .flagsChanged]
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: keyboard) { [weak self] event in
            guard let self = self, self.isActive else { return event }
            return self.handleKey(event) ? nil : event
        }
        installKeyboardTap()
        // ⌘+Space (Spotlight), ⌘+Tab and other system shortcuts are consumed by macOS before any
        // event tap, so turn them off on this Mac while the remote screen is in front.
        hotKeyToken = SymbolicHotKeys.disable()
        layout()
    }

    func leave() {
        guard isActive else { return }
        isActive = false
        SymbolicHotKeys.restore(hotKeyToken)
        hotKeyToken = nil
        stopTrackpad()
        activeView?.releaseInput()
        if let monitor = localMonitor { NSEvent.removeMonitor(monitor) }
        localMonitor = nil
        if let source = tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap = tap { CFMachPortInvalidate(tap) }
        tapSource = nil
        tap = nil
        notifications.forEach(NotificationCenter.default.removeObserver)
        notifications.removeAll()
        if let activity = activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        views.removeAll()
        NSApp.presentationOptions = previousPresentation
    }

    func display(_ views: [RemoteView]) {
        self.views = views
        if views.isEmpty { stopTrackpad() }
        guard isActive else { return }
        layout()
        if !views.isEmpty && builtInTrackpad == nil {
            builtInTrackpad = BuiltInTrackpad { [weak self] positions, time in
                self?.trackBuiltInContacts(positions, at: time)
            }
        }
    }

    private func stopTrackpad() {
        builtInTrackpad?.stop()
        builtInTrackpad = nil
        trackpadView?.cancelBuiltInTrackpadGesture()
        trackpadView = nil
        trackpadSequence = false
    }

    private func trackBuiltInContacts(_ positions: [CGPoint], at time: TimeInterval) {
        if positions.isEmpty {
            trackpadView?.interpretBuiltInTrackpad([], at: time)
            trackpadView = nil
            trackpadSequence = false
            return
        }
        guard isActive, NSApp.isActive else {
            trackpadView?.cancelBuiltInTrackpadGesture()
            trackpadView = nil
            trackpadSequence = true
            return
        }
        if !trackpadSequence {
            trackpadSequence = true
            trackpadView = views.first { $0.isPointerOverRemoteScreen }
        }
        trackpadView?.interpretBuiltInTrackpad(positions, at: time)
    }

    func setActivity(_ activity: OperationActivity) {
        previousActivity = activity
        if views.isEmpty { windows.first?.canvas.setActivity(activity) }
    }

    func status(_ text: String) {
        previousStatus = text
        if views.isEmpty { windows.first?.canvas.setStatus(text) }
    }

    func bringForward() {
        guard isActive else { return }
        NSApp.activate(ignoringOtherApps: true)
        for window in windows { window.orderFrontRegardless() }
        if !windows.contains(where: { $0.isKeyWindow }) { windows.first?.makeKeyAndOrderFront(nil) }
        for window in windows where !(window.firstResponder is RemoteView) {
            if let view = window.canvas.remoteViews.first { window.makeFirstResponder(view) }
        }
    }

    private var activeView: RemoteView? {
        let window = windows.first(where: { $0.isKeyWindow }) ?? windows.first
        return (window?.firstResponder as? RemoteView) ?? window?.canvas.remoteViews.first
    }

    private func layout() {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }
        var next: [ReceiverWindow] = []
        for (index, screen) in screens.enumerated() {
            let window = ReceiverWindow(screen: screen)
            window.canvas.setViews(views.enumerated().compactMap { $0.offset % screens.count == index ? $0.element : nil })
            if index == 0 && views.isEmpty {
                window.canvas.setStatus(previousStatus)
                window.canvas.setActivity(previousActivity)
            }
            next.append(window)
        }
        let previous = windows
        windows = next
        bringForward()
        for window in previous { window.orderOut(nil) }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        if event.type == .flagsChanged && event.keyCode == UInt16(kVK_Function) {
            fnDown = event.modifierFlags.contains(.function)
        }
        if event.type == .keyDown && !event.isARepeat &&
            Self.isExitKey(event.keyCode, flags: event.modifierFlags,
                           fnDown: fnDown || CGEventSource.keyState(.hidSystemState, key: CGKeyCode(kVK_Function))) {
            DispatchQueue.main.async { [weak self] in self?.onExit?() }
            return true
        }
        guard let view = activeView else { return true }
        if event.keyCode == UInt16(kVK_CapsLock) && view.usesNativeCapsSwitch { return false }
        view.handleKey(event)
        return true
    }

    private func installKeyboardTap() {
        let mask = [CGEventType.keyDown, .keyUp, .flagsChanged].reduce(CGEventMask(0)) {
            $0 | (CGEventMask(1) << $1.rawValue)
        }
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context = context else { return Unmanaged.passUnretained(event) }
            let receiver = Unmanaged<ReceiverMode>.fromOpaque(context).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = receiver.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                receiver.activeView?.releaseInput()
                receiver.fnDown = false
            } else if receiver.isActive && NSApp.isActive, let key = NSEvent(cgEvent: event),
                      receiver.handleKey(key) {
                return nil
            }
            return Unmanaged.passUnretained(event)
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        // Take system shortcuts before the receiver's desktop handles them.
        let locations: [CGEventTapLocation] = [.cghidEventTap, .cgSessionEventTap]
        for location in locations {
            guard let eventTap = CGEvent.tapCreate(tap: location, place: .headInsertEventTap, options: .defaultTap,
                                                   eventsOfInterest: mask, callback: callback, userInfo: context)
            else { continue }
            guard let source = CFMachPortCreateRunLoopSource(nil, eventTap, 0) else {
                CFMachPortInvalidate(eventTap)
                continue
            }
            tap = eventTap
            tapSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: eventTap, enable: true)
            break
        }
    }
}

/// Carbon's symbolic hot key mode. The functions are still exported by HIToolbox but are no longer
/// declared in the SDK headers, so they are looked up at run time and skipped when missing.
/// The mode applies only while this app is active and needs Accessibility permission.
enum SymbolicHotKeys {
    private typealias Push = @convention(c) (UInt32) -> UnsafeMutableRawPointer?
    private typealias Pop = @convention(c) (UnsafeMutableRawPointer?) -> Void
    private typealias Get = @convention(c) () -> UInt32
    /// kHIHotKeyModeAllDisabledExceptUniversalAccess keeps zoom and VoiceOver shortcuts working.
    private static let allDisabledExceptUniversalAccess: UInt32 = 1 << 1
    private static let push: Push? = symbol("PushSymbolicHotKeyMode").map { unsafeBitCast($0, to: Push.self) }
    private static let pop: Pop? = symbol("PopSymbolicHotKeyMode").map { unsafeBitCast($0, to: Pop.self) }
    private static let current: Get? = symbol("GetSymbolicHotKeyMode").map { unsafeBitCast($0, to: Get.self) }

    static var available: Bool { push != nil && pop != nil }
    /// The app's current mode: 0 enabled, 2 all disabled except accessibility shortcuts.
    static var mode: UInt32? { current?() }
    static var disabledMode: UInt32 { allDisabledExceptUniversalAccess }

    static func disable() -> UnsafeMutableRawPointer? { push?(allDisabledExceptUniversalAccess) }

    static func restore(_ token: UnsafeMutableRawPointer?) {
        guard let token = token else { return }
        pop?(token)
    }

    private static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)  // RTLD_DEFAULT
    }
}

private final class ReceiverWindow: NSWindow, NSWindowDelegate {
    let canvas = ReceiverCanvas(frame: .zero)

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .black
        isOpaque = true
        hasShadow = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        hidesOnDeactivate = false
        contentView = canvas
        delegate = self
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    func windowShouldClose(_ sender: NSWindow) -> Bool { false }
}

final class ReceiverCanvas: NSView {
    private(set) var remoteViews: [RemoteView] = []
    private let label = NSTextField(wrappingLabelWithString: "")
    private let patch = NSImageView()
    private let mark = ActivityMark()
    private static let patchSize: CGFloat = 94

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        appearance = NSAppearance(named: .darkAqua)
        label.textColor = .white
        label.alignment = .center
        label.font = .systemFont(ofSize: 20)
        label.isHidden = true
        addSubview(label)
        patch.image = GachaArt.patch
        patch.imageScaling = .scaleProportionallyUpOrDown
        patch.wantsLayer = true
        patch.shadow = {
            let glow = NSShadow()
            glow.shadowColor = Palette.gachaLavender.withAlphaComponent(0.45)
            glow.shadowBlurRadius = 28
            glow.shadowOffset = .zero
            return glow
        }()
        patch.setAccessibilityLabel("My Music Gacha")
        patch.isHidden = true
        addSubview(patch)
        mark.translatesAutoresizingMaskIntoConstraints = false
        addSubview(mark)
        NSLayoutConstraint.activate([
            mark.centerXAnchor.constraint(equalTo: centerXAnchor),
            mark.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 18)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func setViews(_ views: [RemoteView]) {
        remoteViews.forEach { $0.removeFromSuperview() }
        remoteViews = views
        for view in views {
            view.removeFromSuperview()
            addSubview(view)
        }
        label.isHidden = true
        patch.isHidden = true
        mark.show(.idle)
        needsLayout = true
    }

    func setActivity(_ activity: OperationActivity) { mark.show(activity) }

    func setStatus(_ text: String) {
        guard !text.isEmpty else { return }
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        centered.paragraphSpacing = 6
        let value = NSMutableAttributedString(string: text + "\n\n", attributes: [
            .foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 20, weight: .medium), .paragraphStyle: centered
        ])
        value.append(NSAttributedString(string: L("설정으로 돌아가기", "Back to settings") + "  ·  " + ReceiverMode.exitKeys,
                                        attributes: [.foregroundColor: NSColor.white.withAlphaComponent(0.62),
                                                     .font: NSFont.systemFont(ofSize: 15), .paragraphStyle: centered]))
        label.attributedStringValue = value
        label.isHidden = false
        patch.isHidden = patch.image == nil
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let columns = Int(ceil(sqrt(Double(max(1, remoteViews.count)))))
        let rows = max(1, (remoteViews.count + columns - 1) / columns)
        let width = bounds.width / CGFloat(columns)
        let height = bounds.height / CGFloat(rows)
        for (index, view) in remoteViews.enumerated() {
            view.frame = NSRect(x: CGFloat(index % columns) * width,
                                y: bounds.height - CGFloat(index / columns + 1) * height,
                                width: width, height: height)
        }
        let size = Self.patchSize
        patch.frame = NSRect(x: bounds.midX - size / 2, y: bounds.midY + 34, width: size, height: size)
        let labelWidth = min(bounds.width * 0.86, 720)
        let labelHeight = ceil(label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: labelWidth, height: 1000)).height ?? 150)
        label.frame = NSRect(x: bounds.midX - labelWidth / 2, y: bounds.midY - labelHeight - 2,
                             width: labelWidth, height: labelHeight)
    }
}

enum ReceiverLogin {
    private static var identifier: String { (Bundle.main.bundleIdentifier ?? "app.finalfusion.remote") + ".login" }
    private static var legacyFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents")
            .appendingPathComponent(identifier + ".plist")
    }

    static var isRegistered: Bool {
        if #available(macOS 13, *) {
            let status = SMAppService.mainApp.status
            return status == .enabled || status == .requiresApproval
        }
        return FileManager.default.fileExists(atPath: legacyFile.path)
    }

    static func setRegistered(_ enabled: Bool, sender: Bool) throws -> String {
        if #available(macOS 13, *) {
            if enabled {
                try SMAppService.mainApp.register()
                if SMAppService.mainApp.status == .requiresApproval {
                    let name = sender ? ProductName.sender : ProductName.receiver
                    return L("시스템 설정 → 일반 → 로그인 항목에서 「\(name)」 앱을 켜 주세요.",
                             "Turn on “\(name)” in System Settings → General → Login Items.")
                }
            } else { try SMAppService.mainApp.unregister() }
        } else {
            let file = legacyFile
            if enabled {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                let plist: [String: Any] = [
                    "Label": identifier, "RunAtLoad": true, "LimitLoadToSessionType": "Aqua",
                    "ProgramArguments": ["/usr/bin/open", "-a", Bundle.main.bundleURL.path]
                ]
                let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                try data.write(to: file, options: .atomic)
            } else if FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.removeItem(at: file)
            }
        }
        if !enabled { return L("로그인 자동 실행을 껐어요.", "Turned off opening at login.") }
        return sender ? L("다음 로그인부터 자동으로 보내기를 준비해요.", "From your next login, sharing gets ready automatically.")
                      : L("다음 로그인부터 받는 앱이 자동으로 열려요.", "From your next login, the viewer opens automatically.")
    }
}
