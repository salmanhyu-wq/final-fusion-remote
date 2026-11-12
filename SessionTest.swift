import AppKit
import AVFoundation
import Carbon.HIToolbox
import CoreImage
import CoreText
import Network
import ScreenCaptureKit
import VideoToolbox

@available(macOS 14, *)
func runSessionTest(output: URL) -> Never {
    func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }

    func waitFor(_ message: String, until ready: () -> Bool) {
        let deadline = Date().addingTimeInterval(8)
        while !ready() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        require(ready(), message)
    }

    let size = CGSize(width: 1280, height: 800)
    let viewport = CGRect(origin: .zero, size: size)
    let options = ReceiverResolution.medium.displayOptions(width: 1280, height: 800)!
    let streamSize = CGSize(width: options.width, height: options.height)
    let pattern = makeScreenPattern(streamSize)
    let moving = [pattern, makeScreenPattern(streamSize, animation: true)]
    if let mode = MatchedDisplay.candidate(for: CGMainDisplayID(), options: options, retina: false) {
        print("Physical monitor candidate: \(mode.width)×\(mode.height) workspace, \(mode.pixelWidth)×\(mode.pixelHeight) pixels")
        require(options.hasMatchingAspect(width: mode.width, height: mode.height), "chosen mode preserves the receiver's aspect ratio")
    }
    require(CaptureGeometry.outputSize(logical: size, source: size, nativeScale: 1, retina: false) == size,
            "host capture matches the receiver workspace")
    let retinaSize = CaptureGeometry.outputSize(logical: size, source: size, nativeScale: 2, retina: true)
    require(retinaSize == CGSize(width: 2560, height: 1600), "high-density capture preserves the same viewport")

    _ = NSApplication.shared
    var capture: Capture?
    var senderWire: Wire?
    var prepared = 0
    var displayReady = false
    var displayChecks = 0
    var started = false
    var inputs: [Input] = []
    let updatePayload = Data(repeating: 0x51, count: 70_000)
    let simulation = StudioHost.Simulation(displays: { wire, receiverOptions in
        require(receiverOptions?.width == 1440 && receiverOptions?.height == 900, "receiver sent medium 16:10 dimensions")
        prepared += 1
        senderWire = wire
        let info = DisplayInfo(id: 1, name: "MacBook test pattern", width: options.width, height: options.height,
                               localCursor: true, followsReceiver: true, macInputMatching: true, receiverUpdates: true,
                               logicalWidth: options.width, logicalHeight: options.height, advancedTrackpad: true,
                               notificationShortcut: true, videoFeedback: true, clipboardScreenshots: true,
                               cursorShapes: true)
        let display = try Capture(info: info, retina: false, wire: wire, interactive: true)
        capture = display
        return [display]
    }, onInput: { inputs.append($0) }, displayReady: {
        displayChecks += 1
        return displayReady
    }, updatePayload: { updatePayload })
    let host = try! StudioHost(simulation: simulation) { status in
        if status.hasPrefix(L("원격 연결 중", "Connected remotely")) {
            started = true
            capture?.submitTestPattern(pattern)
        }
    }
    var localSocket: String?
    host.onReady = { localSocket = $0 }
    try! host.start()
    waitFor("sender listening") { localSocket != nil }
    require(host.activeDisplayCount == 0 && prepared == 0 && !started && displayChecks == 0,
            "idle sender leaves the screen alone")

    let receiverMode = ReceiverMode()
    let viewer = StudioViewer(receiverMode: receiverMode) { _ in }
    viewer.matchInputSource = false
    let canvas = ReceiverCanvas(frame: viewport)
    let client = Wire(NWConnection(to: .unix(path: localSocket!), using: .tcp), queue: .main)
    var received = false
    var recovered = false
    var testedView: RemoteView?
    viewer.onVideoSample = { view, sample in
        if received {
            if !recovered {
                let decoded = decodeScreenPattern(sample)
                require(CVPixelBufferGetWidth(decoded) == options.width, "requested keyframe independently decodes")
                recovered = true
            }
            return
        }
        testedView = view
        received = true
        require(started && prepared == 1 && host.activeDisplayCount == 1, "capture starts after receiver authentication")
        canvas.setViews([view])
        canvas.layout()
        view.layout()
        require(view.displayedRect == viewport && view.image.frame == viewport, "16:10 fills the screen with zero black borders")
        let sendButton = CGPoint(x: 1235, y: 12)
        let target = RemoteView.position(sendButton, in: view.displayedRect)
        require(target.x > 0.95 && target.y > 0.98 && target.y < 1, "lower right button is visible and clickable")
        let decoded = decodeScreenPattern(sample)
        require(CVPixelBufferGetWidth(decoded) == options.width && CVPixelBufferGetHeight(decoded) == options.height,
                "complete 1440×900 image decoded")
        CVPixelBufferLockBaseAddress(decoded, .readOnly)
        let base = CVPixelBufferGetBaseAddressOfPlane(decoded, 0)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(decoded, 0)
        func tone(_ x: Int, _ y: Int) -> Int {
            let px = x * options.width / 1280
            let py = y * options.height / 800
            return Int(base[(options.height - 1 - py) * stride + px])
        }
        for (label, x, y, expected) in screenTestPoints {
            require(abs(tone(x, y) - expected) <= 16, "\(label) survived capture, encode, connection and decode")
        }
        CVPixelBufferUnlockBaseAddress(decoded, .readOnly)
        do {
            let image = CIImage(cvPixelBuffer: decoded)
            let context = CIContext(options: [.useSoftwareRenderer: true])
            try context.writePNGRepresentation(of: image, to: output, format: .RGBA8,
                                               colorSpace: CGColorSpaceCreateDeviceRGB())
            let snapshot = context.createCGImage(image, from: image.extent)!
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            require(ScreenshotClipboard.write(ScreenshotClipboard.representations(snapshot)!, to: board),
                    "sender screenshot is copied as a pasteboard image")
            let pasted = NSImage(pasteboard: board)
            require(pasted != nil && board.data(forType: .png) != nil && board.data(forType: .tiff) != nil,
                    "paste reads an image with PNG and TIFF representations")
        } catch { require(false, "save decoded test frame: \(error)") }

        let three = [CGPoint(x: 0.38, y: 0.30), CGPoint(x: 0.49, y: 0.34), CGPoint(x: 0.61, y: 0.30)]
        let four = three + [CGPoint(x: 0.45, y: 0.12)]
        let center = CGPoint(x: 0.50, y: 0.26)
        func group(_ factor: CGFloat) -> [CGPoint] {
            four.map { CGPoint(x: center.x + ($0.x - center.x) * factor, y: center.y + ($0.y - center.y) * factor) }
        }
        func gesture(_ start: [CGPoint], _ end: [CGPoint], time: TimeInterval, dragging: Bool = false) {
            view.interpretTrackpad(start, at: time, aspect: 0.65, dragging: dragging)
            view.interpretTrackpad(end, at: time + 0.11, aspect: 0.65, dragging: dragging)
            view.interpretTrackpad([], at: time + 0.18, aspect: 0.65)
        }
        gesture(three, three.map { CGPoint(x: $0.x, y: $0.y + 0.14) }, time: 1)
        gesture(three, three.map { CGPoint(x: $0.x, y: $0.y - 0.13) }, time: 2)
        gesture(four, four.map { CGPoint(x: $0.x - 0.16, y: $0.y) }, time: 3)
        gesture(four, four.map { CGPoint(x: $0.x + 0.16, y: $0.y) }, time: 4)
        gesture(group(1.5), group(0.50), time: 5)
        gesture(group(0.50), group(1.5), time: 6)
        gesture(three, three, time: 7)
        gesture(three, three.map { CGPoint(x: $0.x, y: $0.y + 0.17) }, time: 8, dragging: true)
        gesture([CGPoint(x: 0.42, y: 0.4), CGPoint(x: 0.56, y: 0.4)],
                [CGPoint(x: 0.36, y: 0.4), CGPoint(x: 0.62, y: 0.4)], time: 9)
        let edge = [CGPoint(x: 0.91, y: 0.40), CGPoint(x: 0.97, y: 0.56)]
        gesture(edge, edge.map { CGPoint(x: $0.x - 0.25, y: $0.y) }, time: 10)
        let pair = [CGPoint(x: 0.42, y: 0.4), CGPoint(x: 0.58, y: 0.4)]
        gesture(pair, [CGPoint(x: 0.45, y: 0.30), CGPoint(x: 0.55, y: 0.50)], time: 11)
        gesture(pair, pair, time: 12)
        gesture(pair, pair, time: 12.25)

        func key(_ type: NSEvent.EventType, _ code: Int, _ flags: NSEvent.ModifierFlags, _ characters: String) {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 20,
                                               windowNumber: 0, context: nil, characters: characters,
                                               charactersIgnoringModifiers: characters, isARepeat: false, keyCode: UInt16(code))
            else { require(false, "test key event created"); return }
            view.handleKey(event)
        }
        let reverse = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.command.union(.shift).rawValue | 0x10 | 0x02)
        key(.keyDown, kVK_Tab, reverse, "\t")
        key(.keyUp, kVK_Tab, reverse, "\t")
        key(.keyDown, kVK_Escape, [], "\u{1B}")
        key(.keyUp, kVK_Escape, [], "\u{1B}")
        let feedback = VideoFeedback(receivedBytes: 0, requestKeyframe: true)
        require(client.send(.videoFeedback, screen: view.display.id, data: feedback.bytes),
                "receiver can request a new keyframe while the desktop is still")
    }

    var greeting = host.code
    greeting.append(0)
    greeting.append(options.bytes)
    viewer.receive(on: client, greeting: greeting)
    waitFor("an authorized connection checks whether the screen is awake") { displayChecks == 1 }
    require(host.activeDisplayCount == 0 && prepared == 0 && !received,
            "the sender waits for the screen to wake before starting capture")
    displayReady = true
    waitFor("test pattern reached the receiver after wake") { received }
    waitFor("the sender's cursor shape reached the receiver") { testedView?.remoteCursor != nil }
    waitFor("still desktop responds with a fresh keyframe") { recovered }
    waitFor("trackpad actions and repaired shortcut reached the sender") { inputs.count >= 19 }
    let keyboard = inputs.filter { [.flags, .keyDown, .keyUp].contains($0.action) }
    require(inputs.filter { ![.flags, .keyDown, .keyUp].contains($0.action) }.map(\.action) ==
            [.missionControl, .appWindows, .spaceNext, .spacePrevious, .launchApps, .showDesktop,
             .lookup, .zoomIn, .notificationCenter, .rotateLeft, .smartZoom],
            "three and four fingers, pinch, spread, drag conflict, two-finger zoom/rotation and double tap")
    require(keyboard.map(\.action) == [.flags, .flags, .keyDown, .keyUp, .flags, .flags, .keyDown, .keyUp] &&
            keyboard.map(\.a) == [kVK_RightCommand, kVK_Shift, kVK_Tab, kVK_Tab, kVK_RightCommand, kVK_Shift, kVK_Escape, kVK_Escape] &&
            keyboard[0].b == 1 && keyboard[1].b == 1 && keyboard[4].b == 0 && keyboard[5].b == 0 &&
            CGEventFlags(rawValue: keyboard[2].flags).contains([.maskCommand, .maskShift]) && keyboard[6].flags == 0,
            "right Command and Shift are repaired before Tab and released before the next unmodified key")
    if let view = testedView {
        func key(_ type: NSEvent.EventType, _ code: Int, _ flags: NSEvent.ModifierFlags, _ text: String) {
            view.handleKey(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 21,
                                           windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text,
                                           isARepeat: false, keyCode: UInt16(code))!)
        }
        key(.keyDown, kVK_ANSI_3, [.control, .option, .command], "3")
        key(.keyUp, kVK_ANSI_3, [.control, .option, .command], "3")
        key(.keyDown, kVK_ANSI_V, [.command], "v")
        key(.keyUp, kVK_ANSI_V, [.command], "v")
        waitFor("screenshot and paste commands reach the sender") {
            inputs.contains { $0.action == .keyUp && $0.a == kVK_ANSI_V }
        }
        guard let copy = inputs.firstIndex(where: { $0.action == .screenshotFull }),
              let paste = inputs.firstIndex(where: { $0.action == .keyDown && $0.a == kVK_ANSI_V }) else {
            require(false, "remote screenshot and paste delivered"); exit(1)
        }
        require(copy < paste && !inputs.contains { $0.action == .keyDown && $0.a == kVK_ANSI_3 },
                "screenshot goes to the sender as a capture request before remote paste")

        // ⌘+Space (Spotlight) and ⌘+Tab must reach the sender as plain Command chords.
        let beforeSystemKeys = inputs.count
        let leftCommand = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.command.rawValue | 0x08)
        key(.keyDown, kVK_Space, leftCommand, " ")
        key(.keyUp, kVK_Space, leftCommand, " ")
        key(.keyDown, kVK_Tab, leftCommand, "\t")
        key(.keyUp, kVK_Tab, leftCommand, "\t")
        key(.keyDown, kVK_Escape, [], "\u{1B}")
        key(.keyUp, kVK_Escape, [], "\u{1B}")
        waitFor("⌘+Space and ⌘+Tab reach the sender") {
            inputs.dropFirst(beforeSystemKeys).contains { $0.action == .keyUp && $0.a == kVK_Escape }
        }
        let systemKeys = inputs.dropFirst(beforeSystemKeys).filter { [.flags, .keyDown, .keyUp].contains($0.action) }
        // The sender must see Command held when Space and Tab go down (it may still be held from ⌘+V).
        func commandHeld(before key: Int) -> Bool {
            guard let index = inputs.lastIndex(where: { $0.action == .keyDown && $0.a == key }) else { return false }
            let last = inputs[..<index].last { $0.action == .flags && [kVK_Command, kVK_RightCommand].contains($0.a) }
            return last?.b == 1 && CGEventFlags(rawValue: inputs[index].flags).contains(.maskCommand)
        }
        require(commandHeld(before: kVK_Space) && commandHeld(before: kVK_Tab) &&
                systemKeys.contains { $0.action == .flags && [kVK_Command, kVK_RightCommand].contains($0.a) && $0.b == 0 },
                "Command is held at the sender for Space and Tab and released before the next plain key: " +
                systemKeys.map { "\($0.action.rawValue) a=\($0.a) b=\($0.b) f=\(String($0.flags, radix: 16))" }.joined(separator: ", "))

        let overlay = view.layer?.sublayers?.first { $0.name == "pointer-feedback" }
        let ring = overlay?.sublayers?.first { $0.name == "click-ring" }
        let hourglass = overlay?.sublayers?.first { $0.name == "click-hourglass" }
        func mouse(_ type: NSEvent.EventType, at point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                               eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
        }
        let start = CGPoint(x: 610, y: 400)
        let receiveNormally = client.onMessage
        // Drain the earlier gesture probes before testing new input in isolation.
        view.releaseInput()
        let barrier = Data([0, 0, 0, 0, 0, 0, 0, 42])
        var synchronized = false
        client.onMessage = { kind, id, data in
            if kind == .keepAlive && data == barrier { synchronized = true }
            else { receiveNormally?(kind, id, data) }
        }
        client.send(.keepAlive, data: barrier)
        waitFor("earlier gesture receipts have drained") { synchronized }

        var heldEchoes: [(UInt32, Data)] = []
        client.onMessage = { kind, id, data in
            if kind == .keepAlive { heldEchoes.append((id, data)) }
            else { receiveNormally?(kind, id, data) }
        }
        view.mouseDown(with: mouse(.leftMouseDown, at: start))
        require(ring?.animation(forKey: "click") != nil, "click flash is local and starts before any sender response")
        view.mouseUp(with: mouse(.leftMouseUp, at: start))
        require(hourglass?.isHidden == true, "fast clicks have a grace period before the hourglass")
        waitFor("click receipt follows the button release at the sender") { heldEchoes.count == 1 }
        require(inputs.last?.action == .up, "the echo follows the actual mouse-up")
        waitFor("late click shows a pixel hourglass") { hourglass?.isHidden == false }
        let edge = CGPoint(x: viewport.maxX - 3, y: viewport.minY + 3)
        view.mouseMoved(with: mouse(.mouseMoved, at: edge))
        require(hourglass.map { $0.frame.maxX < edge.x && $0.frame.minY > edge.y } == true,
                "the hourglass follows the mouse and stays inside the screen")
        view.mouseDown(with: mouse(.leftMouseDown, at: edge))
        view.mouseUp(with: mouse(.leftMouseUp, at: edge))
        waitFor("second click has its own receipt") { heldEchoes.count == 2 }
        receiveNormally?(.keepAlive, heldEchoes[0].0, heldEchoes[0].1)
        require(hourglass?.isHidden == false, "an older receipt cannot clear the latest click")
        receiveNormally?(.keepAlive, heldEchoes[1].0, heldEchoes[1].1)
        require(hourglass?.isHidden == true, "the latest receipt clears the wait without another video frame")
        print("PASS: local click flash, delayed pixel hourglass, cursor following, and ordered click receipts")

        func deliverEcho() {
            let echo = heldEchoes.removeFirst()
            receiveNormally?(.keepAlive, echo.0, echo.1)
        }
        heldEchoes.removeAll()
        let scroll = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                             wheel1: -12, wheel2: 2, wheel3: 0)!
        scroll.location = CGPoint(x: start.x, y: CGDisplayBounds(CGMainDisplayID()).height - start.y)
        let scrollEvent = NSEvent(cgEvent: scroll)!
        let beforeScroll = inputs.count
        view.scrollWheel(with: scrollEvent)
        waitFor("first scroll requests an input receipt") { heldEchoes.count == 1 }
        for _ in 0..<12 { view.scrollWheel(with: scrollEvent) }
        waitFor("trailing receipt covers the scroll burst") { heldEchoes.count >= 2 }
        require(heldEchoes.count == 2 && inputs.dropFirst(beforeScroll).filter { $0.action == .scroll }.count == 13,
                "all scroll events are forwarded with two receipt probes")
        require(hourglass?.isHidden == true, "recent scroll probes have a grace period")
        deliverEcho()
        RunLoop.main.run(until: Date().addingTimeInterval(0.075))
        require(hourglass?.isHidden == true, "an answered scroll probe does not age the following one")
        waitFor("a late scroll receipt shows the hourglass") { hourglass?.isHidden == false }
        deliverEcho()
        require(hourglass?.isHidden == true, "scroll recovery clears the hourglass")

        let fingers = [CGPoint(x: 0.38, y: 0.30), CGPoint(x: 0.49, y: 0.34), CGPoint(x: 0.61, y: 0.30)]
        view.interpretTrackpad(fingers, at: 30, aspect: 0.65)
        view.interpretTrackpad(fingers.map { CGPoint(x: $0.x, y: $0.y + 0.14) }, at: 30.11, aspect: 0.65)
        view.interpretTrackpad([], at: 30.18, aspect: 0.65)
        waitFor("three-finger swipe requests an input receipt") { heldEchoes.count == 1 }
        require(inputs.last?.action == .missionControl, "the actual swipe reached the host before its receipt")
        waitFor("a late gesture receipt shows the hourglass") { hourglass?.isHidden == false }
        deliverEcho()
        require(hourglass?.isHidden == true, "gesture recovery clears the hourglass")

        viewer.sendHeartbeat()
        waitFor("connection health probe gets an echo") { heldEchoes.count == 1 }
        require(hourglass?.isHidden == true, "an idle connection can respond before the warning")
        waitFor("late connection shows the hourglass without input or a new frame") { hourglass?.isHidden == false }
        deliverEcho()
        require(hourglass?.isHidden == false, "a slow health echo does not imply recovery")
        view.mouseDown(with: mouse(.leftMouseDown, at: start))
        view.mouseUp(with: mouse(.leftMouseUp, at: start))
        waitFor("click still receives its own confirmation") { heldEchoes.count == 1 }
        deliverEcho()
        require(hourglass?.isHidden == false, "an input receipt does not erase connection trouble")
        viewer.sendHeartbeat()
        waitFor("the next connection probe returns promptly") { heldEchoes.count == 1 }
        deliverEcho()
        require(hourglass?.isHidden == true, "a healthy echo clears the connection warning")
        client.onMessage = receiveNormally
        print("PASS: scroll batching, delayed trackpad gesture, idle connection warning, and recovery")

        let beforeBuiltIn = inputs.count
        let moved = fingers.map { CGPoint(x: $0.x, y: $0.y + 0.14) }
        view.interpretBuiltInTrackpad(fingers, at: 40)
        view.interpretBuiltInTrackpad(moved, at: 40.11)
        view.interpretBuiltInTrackpad([], at: 40.16)
        // The normal AppKit path can report the same swipe as well.
        view.interpretTrackpad(fingers, at: 40.03, aspect: 0.65)
        view.interpretTrackpad(moved, at: 40.14, aspect: 0.65)
        view.interpretTrackpad([], at: 40.17, aspect: 0.65)
        view.interpretBuiltInTrackpad(fingers, at: 40.3, dragging: true)
        view.interpretBuiltInTrackpad(moved, at: 40.4, dragging: true)
        view.interpretBuiltInTrackpad([], at: 40.5)
        let right = fingers.map { CGPoint(x: $0.x + 0.17, y: $0.y) }
        view.interpretBuiltInTrackpad(fingers, at: 41)
        view.interpretBuiltInTrackpad(right, at: 41.11)
        view.interpretBuiltInTrackpad([], at: 41.16)
        waitFor("built-in trackpad actions reach the sender") { inputs.count >= beforeBuiltIn + 2 }
        require(inputs.dropFirst(beforeBuiltIn).map(\.action) == [.missionControl, .spacePrevious],
                "built-in contacts work without AppKit, do not duplicate commands, and ignore drags")
        print("PASS: built-in multitouch contact routing and duplicate suppression")
    }
    if let send = testedView?.send {
        let before = inputs.count
        for step in 1...120 {
            send(Input(action: .move, display: 1, x: Double(step) / 120, y: 0.5))
        }
        send(Input(action: .down, display: 1, x: 1, y: 0.5))
        send(Input(action: .move, display: 1, x: 0.8, y: 0.5, pressure: 1))
        send(Input(action: .up, display: 1, x: 0.8, y: 0.5))
        send(Input(action: .keyDown, display: 1, a: kVK_ANSI_A))
        send(Input(action: .keyUp, display: 1, a: kVK_ANSI_A))
        send(Input(action: .scroll, display: 1, x: 0.8, y: 0.5, a: 8))
        waitFor("input burst reaches the sender") { inputs.count >= before + 7 && inputs.last?.action == .scroll }
        let burst = Array(inputs.dropFirst(before))
        let motion = burst.filter { $0.sequence == nil }
        let ordered = burst.filter { $0.sequence != nil }
        require((1...2).contains(motion.count) && motion.last?.x == 1,
                "the last idle pointer position survives without a backlog")
        require(ordered.map(\.action) == [.down, .move, .up, .keyDown, .keyUp, .scroll] &&
                ordered[1].pressure == 1 && ordered[3].a == kVK_ANSI_A &&
                zip(ordered, ordered.dropFirst()).allSatisfy { pair in
                    pair.0.sequence! + 1 == pair.1.sequence!
                }, "click, drag, key, and scroll events arrive exactly once in order")
        print("PASS: idle pointer burst is compressed and ordered input arrives intact")
    }
    var resolutionRequests: [ReceiverResolution] = []
    viewer.onResolutionRequested = { resolutionRequests.append($0) }
    func sendResolution(_ session: UUID, then token: UInt32) {
        let request = ReceiverResolutionRequest(id: UUID(), session: session, resolution: .low, issuedAt: Date())
        require(senderWire?.send(.receiverControl, data: try! JSONEncoder().encode(request)) == true,
                "sender can encode and deliver a resolution request")
        var marker = Data()
        marker.put(0x52534C54)
        marker.put(token)
        var seenMarker = false
        let receiveNormally = client.onMessage
        client.onMessage = { kind, id, data in
            if kind == .keepAlive, data == marker { seenMarker = true }
            else { receiveNormally?(kind, id, data) }
        }
        senderWire?.send(.keepAlive, data: marker)
        waitFor("resolution request was received before its marker") { seenMarker }
        client.onMessage = receiveNormally
    }
    sendResolution(viewer.diagnosticSession, then: 1)
    require(resolutionRequests.isEmpty, "receiver declines adjustment before opting in")
    viewer.remoteTuningAllowed = true
    sendResolution(UUID(), then: 2)
    require(resolutionRequests.isEmpty, "receiver declines requests for another connection")
    sendResolution(viewer.diagnosticSession, then: 3)
    require(resolutionRequests == [.low], "receiver accepts the selected resolution for its own opted-in connection")
    print("PASS: remote resolution request is restricted to the opted-in receiver connection")
    var fallbackSize: CGSize?
    let screenshotArea = ScreenshotRegion(first: .zero, last: CGPoint(x: 0.5, y: 0.5))
    capture?.screenshot(screenshotArea) { image in
        DispatchQueue.main.async { fallbackSize = image.map { CGSize(width: $0.width, height: $0.height) } ?? .zero }
    }
    waitFor("sender screenshot is available from the live capture") { fallbackSize != nil }
    require(fallbackSize == CGSize(width: 720, height: 450), "sender capture can copy the selected region")
    require(capture?.diagnostics().targetFPS == 60, "medium resolution targets 60 frames per second")
    var submitted = 0
    var receivedWhileMoving = 0
    viewer.onVideoSample = { _, _ in receivedWhileMoving += 1 }
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now(), repeating: .nanoseconds(16_666_667), leeway: .microseconds(200))
    timer.setEventHandler {
        capture?.submitTestPattern(moving[submitted % moving.count])
        submitted += 1
        if submitted == 120 { timer.cancel() }
    }
    timer.resume()
    waitFor("120 animation frames submitted at 60fps") { submitted == 120 }
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    print("1440×900 loopback motion: \(receivedWhileMoving)/120 frames submitted to receiver display")
    require(receivedWhileMoving >= 106, "receiver keeps up with the 60fps local test")
    let beforePause = receivedWhileMoving
    capture?.pauseForUpdate(true)
    capture?.submitTestPattern(moving[0])
    RunLoop.main.run(until: Date().addingTimeInterval(0.15))
    require(receivedWhileMoving == beforePause, "video waits while the sender transfers an update")
    capture?.pauseForUpdate(false)
    waitFor("video resumes with the latest frame after the update") { receivedWhileMoving > beforePause }

    // Keep the socket open while delaying delivery to the viewer and its receipts.
    let receiveNormally = client.onMessage
    var heldMessages: [(Kind, UInt32, Data)] = []
    client.onMessage = { heldMessages.append(($0, $1, $2)) }
    let stalledLink = DispatchSource.makeTimerSource(queue: .main)
    var framesDuringStall = 0
    stalledLink.schedule(deadline: .now(), repeating: .nanoseconds(16_666_667))
    stalledLink.setEventHandler {
        capture?.submitTestPattern(moving[framesDuringStall % moving.count])
        framesDuringStall += 1
        if framesDuringStall % 60 == 0 { client.send(.keepAlive) }
    }
    stalledLink.resume()
    waitFor("sender drops to 20 fps before delayed video receipts resume") { capture?.diagnostics().targetFPS == 20 }
    require(!heldMessages.isEmpty && capture?.info.width == 1440 && capture?.info.height == 900,
            "the congestion response changes cadence without changing resolution")
    client.onMessage = receiveNormally
    for (kind, id, data) in heldMessages { receiveNormally?(kind, id, data) }
    heldMessages.removeAll()
    waitFor("frame rate recovers after delivery stabilizes") { (capture?.diagnostics().targetFPS ?? 0) >= 30 }
    stalledLink.cancel()
    print("PASS: simulated late video delivery lowered the target from 60 to 20 fps and recovered to 30 fps at the same resolution")
    viewer.stop()
    waitFor("disconnection releases all sender displays") { host.activeDisplayCount == 0 }
    require(capture?.isIdle == true, "disconnection stops the encoder")

    let checker = StudioViewer { _ in }
    var checked: ReceiverUpdateVersion?
    checker.onUpdateVersion = { checked = $0 }
    var queryGreeting = host.code
    queryGreeting.append(ReceiverUpdatePhase.checkOnlyGreeting)
    let queryWire = Wire(NWConnection(to: .unix(path: localSocket!), using: .tcp), queue: .main)
    checker.receive(on: queryWire, greeting: queryGreeting)
    waitFor("receiver can check for an update without starting a screen session") { checked != nil }
    require(checked == ReceiverUpdateVersion.current && host.activeDisplayCount == 0 && prepared == 1,
            "version query returns the sender version and does not start screen capture")
    checker.stop()
    require(displayChecks == 2, "version-only session does not check or wake the display")
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))

    host.receiverProfile = ReceiverProfile(relay: "https://example.invalid",
                                           room: String(repeating: "11", count: 32),
                                           pin: String(repeating: "22", count: 32),
                                           invitation: String(repeating: "33", count: 16), macPin: nil)
    let installed = ReceiverUpdateVersion.current!
    let older = ReceiverUpdateVersion("1.0.0")!
    require(older < installed, "test viewer reports the released older version")

    func checkDIYTransfer(version: ReceiverUpdateVersion, checkOnly: Bool, sendsUpdate: Bool) {
        var announcedVersion: ReceiverUpdateVersion?
        host.onReceiverVersion = { announcedVersion = $0 }
        var received = false
        var download: ReceiverUpdateDownload?
        var acknowledged = false
        host.onUpdateStatus = { message in
            if message.hasPrefix(L("파일을 보냈어요.", "Update sent.")) { acknowledged = true }
        }
        let connection = Wire(NWConnection(to: .unix(path: localSocket!), using: .tcp), queue: .main)
        var greeting = host.code
        greeting.append(checkOnly ? ReceiverUpdatePhase.checkOnlyGreeting : 0)
        if !checkOnly { greeting.append(options.bytes) }
        connection.onReady = { [weak connection] in connection?.send(.hello, data: greeting) }
        connection.onMessage = { [weak connection] kind, id, data in
            if kind == .screens || (kind == .receiverUpdate && id == ReceiverUpdatePhase.version.rawValue) {
                connection?.send(.receiverUpdate, screen: ReceiverUpdatePhase.version.rawValue, data: Data(version.label.utf8))
            }
            guard kind == .receiverUpdate, let phase = ReceiverUpdatePhase(rawValue: id) else { return }
            switch phase {
            case .offer:
                let offer = try! JSONDecoder().decode(ReceiverUpdateOffer.self, from: data)
                require(offer.isNewer(than: version), "sender offers only a newer build")
                download = ReceiverUpdateDownload(offer: offer)
            case .chunk:
                require(download?.append(data) == true, "legacy viewer accepts each update chunk")
            case .complete:
                require(download?.payload == updatePayload && download?.offer.matches(updatePayload) == true,
                        "viewer received the complete, verifiable update")
                received = true
                connection?.send(.receiverUpdate, screen: ReceiverUpdatePhase.result.rawValue, data: Data([1]))
            default: break
            }
        }
        connection.start()
        waitFor("viewer version arrives through the protocol") { announcedVersion == version }
        if checkOnly || !sendsUpdate {
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            require(download == nil, "no unsolicited file during a legacy version check or when already up to date")
        }
        if checkOnly && sendsUpdate {
            connection.send(.receiverUpdate, screen: ReceiverUpdatePhase.request.rawValue)
        }
        if sendsUpdate {
            waitFor("sender transfers the file and acknowledges receipt") { received && acknowledged }
        }
        connection.close()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        waitFor("DIY connection releases any captures") { host.activeDisplayCount == 0 }
    }
    checkDIYTransfer(version: older, checkOnly: false, sendsUpdate: true)
    checkDIYTransfer(version: older, checkOnly: true, sendsUpdate: true)
    checkDIYTransfer(version: installed, checkOnly: false, sendsUpdate: false)
    host.onReceiverVersion = nil
    host.onUpdateStatus = nil
    print("PASS: older viewers get the update automatically or by legacy request until they report the installed version")
    host.stop()
    print("PASS: idle and update-only sessions leave display power alone, and an authorized receiver starts after display wake")
    testNativeStartupAfterScreenSaver()
    testScreenSaverRemoteAccess()
    testHostSound()
    print("PASS: no capture at idle, full-screen borders and bottom controls, cursor shape, eleven gesture actions, repaired keyboard shortcut, ⌘+Space and ⌘+Tab, encoder stopped")
    exit(0)
}

@available(macOS 14, *)
private func testNativeStartupAfterScreenSaver() {
    func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
    func run(_ seconds: TimeInterval, until ready: () -> Bool = { false }) {
        let deadline = Date().addingTimeInterval(seconds)
        while !ready() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    let pixels = ReceiverNativePixels(width: 2560, height: 1600)!
    let options = ReceiverResolution.native.displayOptions(width: 1280, height: 800)!
    var saver = true
    var settled = false
    var capture: Capture?
    var localSocket: String?
    var connected = false
    var firstPicture: Int?
    let simulation = StudioHost.Simulation(displays: { _, _ in
        require(false, "transient screen saver and mode change should preserve native quality")
        return []
    }, onInput: { _ in }, screenSaverActive: { saver }, nativeDisplay: { wire, requested in
        require(requested == pixels, "viewer requested original pixel dimensions")
        let info = DisplayInfo(id: 2, name: "Native startup test", width: pixels.width, height: pixels.height, nativePixels: true)
        let screen = try Capture(info: info, retina: true, wire: wire, interactive: false)
        capture = screen
        return screen
    }, nativeModeReady: { settled })
    let host = try! StudioHost(simulation: simulation) { _ in }
    host.onReady = { localSocket = $0 }
    try! host.start()
    run(3) { localSocket != nil }
    require(localSocket != nil, "native startup listener opened")
    let mode = ReceiverMode()
    let viewer = StudioViewer(receiverMode: mode) { _ in }
    viewer.resolution = .native
    viewer.matchInputSource = false
    viewer.onConnected = { connected = true }
    viewer.onVideoSample = { view, sample in
        guard firstPicture == nil else { return }
        require(view.display.nativePixels == true, "viewer kept original quality after the wait")
        let image = decodeScreenPattern(sample)
        CVPixelBufferLockBaseAddress(image, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        let offset = CVPixelBufferGetBytesPerRowOfPlane(image, 0) * (pixels.height / 2) + pixels.width / 3
        firstPicture = Int(CVPixelBufferGetBaseAddressOfPlane(image, 0)!.load(fromByteOffset: offset, as: UInt8.self))
    }
    defer { viewer.stop(); host.stop(); run(0.1); withExtendedLifetime(mode) {} }
    let wire = Wire(NWConnection(to: .unix(path: localSocket!), using: .tcp), queue: .main)
    var greeting = host.code
    greeting.append(1)
    greeting.append(options.bytes)
    greeting.append(pixels.bytes)
    viewer.receive(on: wire, greeting: greeting)
    run(0.25)
    require(capture == nil && !connected, "screen saver blocks display preparation")
    saver = false
    run(2) { capture != nil }
    require(capture != nil, "display preparation began after screen saver ended")
    let wallpaper = makeScreenPattern(pixels.size)
    CVPixelBufferLockBaseAddress(wallpaper, [])
    memset(CVPixelBufferGetBaseAddressOfPlane(wallpaper, 0)!, 110,
           CVPixelBufferGetBytesPerRowOfPlane(wallpaper, 0) * pixels.height)
    CVPixelBufferUnlockBaseAddress(wallpaper, [])
    let desktop = makeScreenPattern(pixels.size)
    run(0.06)
    capture?.submitTestScreenFrame(wallpaper, status: .complete)
    run(0.42)
    require(!connected && firstPicture == nil, "a correctly sized frame cannot bypass an unsettled display mode")
    capture?.submitTestScreenFrame(nil, status: .suspended)
    run(0.08)
    settled = true
    run(0.18)
    require(!connected && firstPicture == nil, "the old wallpaper cannot become the first frame after a suspension")
    capture?.submitTestScreenFrame(desktop, status: .complete)
    run(4) { firstPicture != nil }
    require(connected && firstPicture.map { abs($0 - 44) < 14 } == true,
            "the first image the viewer decodes is the restored desktop")
    print("PASS: screen saver and unsettled resolution delay startup; suspended wallpaper is replaced by fresh native video")
}

@available(macOS 14, *)
private func testScreenSaverRemoteAccess() {
    func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
    func wait(_ seconds: TimeInterval, until ready: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while !ready() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }
    let options = ReceiverResolution.native.displayOptions(width: 1280, height: 800)!
    let pixels = ReceiverNativePixels(width: 2560, height: 1600)!
    var saver = true
    var localSocket: String?
    var temporaryDisplay: DisplayInfo?
    var ended = false
    let simulation = StudioHost.Simulation(displays: { wire, _ in
        let display = DisplayInfo(id: 3, name: "Current display", width: 1600, height: 1000)
        return [try Capture(info: display, retina: true, wire: wire, interactive: false)]
    }, onInput: { input in
        if input.action == .move { saver = false }
    }, screenSaverActive: { saver }, nativeDisplay: { _, _ in
        fputs("FAIL: persistent saver started changing resolution\n", stderr)
        exit(1)
    })
    let host = try! StudioHost(simulation: simulation) { _ in }
    host.onReady = { localSocket = $0 }
    try! host.start()
    wait(3) { localSocket != nil }
    require(localSocket != nil, "saver remote-access listener opened")
    let wire = Wire(NWConnection(to: .unix(path: localSocket!), using: .tcp), queue: .main)
    var greeting = host.code
    greeting.append(1)
    greeting.append(options.bytes)
    greeting.append(pixels.bytes)
    wire.onReady = { [weak wire] in wire?.send(.hello, data: greeting) }
    wire.onMessage = { kind, _, data in
        if kind == .screens { temporaryDisplay = (try? JSONDecoder().decode([DisplayInfo].self, from: data))?.first }
    }
    wire.onEnd = { _ in ended = true }
    wire.start()
    defer { wire.close(); host.stop() }
    wait(10) { temporaryDisplay != nil }
    require(saver && temporaryDisplay?.id == 3 && temporaryDisplay?.nativePixels != true,
            "persistent saver leaves the current display and remote input available")
    let move = try! JSONEncoder().encode(Input(action: .move, display: 3, x: 0.5, y: 0.5))
    require(wire.send(.input, data: move), "viewer can send input to dismiss the saver")
    wait(4) { ended }
    require(!saver && ended, "host ends the temporary session so the viewer can reconnect at full quality")
    print("PASS: persistent screen saver keeps remote input available and triggers a fresh connection after dismissal")
}

/// Captures this Mac's real sound for a few seconds the way a session does: the stream starts silent and sound is
/// switched on afterwards. It needs Screen Recording permission, so open the signed app with this argument.
@available(macOS 14, *)
func runAudioCaptureTest(output: URL) -> Never {
    final class Listener: NSObject, SCStreamOutput {
        let encoder = AudioEncoder(), decoder = AudioDecoder()
        var pictures = 0, buffers = 0, packets = 0, bytes = 0, frames = 0
        var format = ""
        var peak: Float = 0
        func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
            if type == .screen { pictures += 1; return }
            guard type == .audio else { return }
            buffers += 1
            if format.isEmpty, let source = sample.formatDescription?.audioStreamBasicDescription {
                format = "\(Int(source.mSampleRate)) Hz, \(source.mChannelsPerFrame) channels, \(source.mBitsPerChannel) bits, flags \(source.mFormatFlags)"
            }
            for packet in encoder.encode(sample) {
                packets += 1
                bytes += packet.count
                guard let sound = decoder.decode(packet), let channel = sound.floatChannelData?[0] else { continue }
                frames += Int(sound.frameLength)
                for index in 0..<Int(sound.frameLength) { peak = max(peak, abs(channel[index])) }
            }
        }
    }
    let listener = Listener()
    let queue = DispatchQueue(label: "studio-remote.audio-capture-test")
    var lines: [String] = []
    var stream: SCStream?
    // The speakers are muted for the test, as they are while a viewer listens; capture must still hear the Mac.
    let speaker = HostSpeakerMute()
    speaker.mute()
    lines.append("speakers muted for the test: \(speaker.isActive)")
    func finish(_ passed: Bool) -> Never {
        speaker.restore()
        lines.append(passed ? "PASS: real host sound was captured, packed and decoded" : "FAIL: no host sound packets")
        try? lines.joined(separator: "\n").appending("\n").write(to: output, atomically: true, encoding: .utf8)
        exit(passed ? 0 : 1)
    }
    SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
        guard let display = content?.displays.first else {
            lines.append("no display: \(error?.localizedDescription ?? "none")")
            finish(false)
        }
        let config = SCStreamConfiguration()
        config.width = 320
        config.height = 200
        config.capturesAudio = false
        let capture = SCStream(filter: SCContentFilter(display: display, excludingApplications: [], exceptingWindows: []),
                               configuration: config, delegate: nil)
        stream = capture
        do { try capture.addStreamOutput(listener, type: .screen, sampleHandlerQueue: queue) }
        catch { lines.append("picture output: \(error.localizedDescription)"); finish(false) }
        capture.startCapture { error in
            if let error { lines.append("start: \(error.localizedDescription)"); finish(false) }
            queue.asyncAfter(deadline: .now() + 1) {
                lines.append("sound buffers before switching on: \(listener.buffers)")
                do { try capture.addStreamOutput(listener, type: .audio, sampleHandlerQueue: queue) }
                catch { lines.append("sound output: \(error.localizedDescription)") }
                config.capturesAudio = true
                config.sampleRate = Int(SessionAudio.sampleRate)
                config.channelCount = SessionAudio.channels
                config.excludesCurrentProcessAudio = true
                capture.updateConfiguration(config) { error in
                    queue.async { lines.append("switch on: \(error?.localizedDescription ?? "ok")") }
                }
            }
            queue.asyncAfter(deadline: .now() + 6) {
                lines.append("pictures \(listener.pictures), sound buffers \(listener.buffers), source \(listener.format)")
                lines.append("packets \(listener.packets), \(listener.bytes) bytes, decoded frames \(listener.frames), peak \(listener.peak)")
                capture.stopCapture { _ in finish(listener.packets > 0 && listener.frames > 0) }
            }
        }
    }
    withExtendedLifetime(stream) { dispatchMain() }
}

@available(macOS 14, *)
private func testHostSound() {
    func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
    func wait(_ seconds: TimeInterval, until ready: () -> Bool = { false }) {
        let deadline = Date().addingTimeInterval(seconds)
        while !ready() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }
    var capture: Capture?
    var localSocket: String?
    let simulation = StudioHost.Simulation(displays: { wire, _ in
        let display = DisplayInfo(id: 4, name: "Sound test", width: 1280, height: 800, localCursor: true, audio: true)
        let screen = try Capture(info: display, retina: false, wire: wire, interactive: true)
        capture = screen
        return [screen]
    }, onInput: { _ in })
    let host = try! StudioHost(simulation: simulation) { _ in }
    host.onReady = { localSocket = $0 }
    try! host.start()
    wait(3) { localSocket != nil }
    require(localSocket != nil, "sound test listener opened")
    defer { host.stop(); wait(0.1) }
    var greeting = host.code
    greeting.append(0)
    var phase = 0.0
    func play(_ tenths: Int) {
        for _ in 0..<tenths { capture?.submitTestAudio(makeTestTone(frames: 4_800, phase: &phase)) }
    }

    // A viewer that never asks, like every viewer before 1.0.7, must not get a message kind it cannot read.
    let wire = Wire(NWConnection(to: .unix(path: localSocket!), using: .tcp), queue: .main)
    var offered: DisplayInfo?
    var packets: [(number: UInt32, data: Data)] = []
    var ended = false
    wire.onReady = { [weak wire] in wire?.send(.hello, data: greeting) }
    wire.onMessage = { kind, id, data in
        if kind == .screens { offered = (try? JSONDecoder().decode([DisplayInfo].self, from: data))?.first }
        if kind == .audio { packets.append((id, data)) }
    }
    wire.onEnd = { _ in ended = true }
    wire.start()
    wait(10) { offered != nil }
    require(offered?.audio == true && capture != nil, "host offers its sound")
    play(5)
    wait(0.3)
    require(packets.isEmpty && !ended, "sound stays off until the viewer asks")
    func ask(_ on: Bool) {
        let request = try! JSONEncoder().encode(Input(action: .audio, display: 4, b: on ? 1 : 0))
        require(wire.send(.input, data: request), "viewer can switch host sound")
        wait(0.15)
    }
    ask(true)
    play(10)
    wait(4) { packets.count >= 40 }
    require(packets.count >= 40 && packets.enumerated().allSatisfy { $0.element.number == UInt32($0.offset) },
            "sound packets arrive numbered in order")
    let decoder = AudioDecoder()
    var heard: [Float] = []
    for packet in packets {
        guard let buffer = decoder.decode(packet.data), let channel = buffer.floatChannelData?[0] else { continue }
        heard.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }
    require(testToneShare(Array(heard.suffix(19_200))) > 0.9, "the viewer decodes the host's tone")
    ask(false)
    let stoppedAt = packets.count
    play(5)
    wait(0.3)
    require(packets.count == stoppedAt && !ended, "sound stops when the viewer turns it off")
    wire.close()
    wait(2) { host.activeDisplayCount == 0 }

    // The real viewer asks by itself and hands decoded sound to its player.
    capture = nil
    let mode = ReceiverMode()
    let viewer = StudioViewer(receiverMode: mode) { _ in }
    viewer.matchInputSource = false
    var connected = false
    var decodedFrames = 0
    var tail: [Float] = []
    viewer.onConnected = { connected = true }
    viewer.onAudioDecoded = { buffer in
        let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        DispatchQueue.main.async {
            decodedFrames += samples.count
            tail = Array((tail + samples).suffix(19_200))
        }
    }
    defer { viewer.stop(); withExtendedLifetime(mode) {} }
    viewer.receive(on: Wire(NWConnection(to: .unix(path: localSocket!), using: .tcp), queue: .main), greeting: greeting)
    wait(10) { connected && capture != nil }
    require(connected && capture != nil, "viewer connected for sound")
    wait(0.3)
    play(10)
    wait(4) { decodedFrames >= 40_000 }
    require(decodedFrames >= 40_000 && testToneShare(tail) > 0.9, "the viewer app asks for sound and decodes it")
    print("PASS: host sound reaches only viewers that ask for it, in order, and stops on request")
}

private let screenTestPoints = [
    ("top border", 630, 797, 135), ("bottom border", 630, 2, 200),
    ("left border", 2, 400, 118), ("right border", 1277, 400, 155),
    ("model selector", 224, 13, 98), ("message field", 560, 49, 70), ("send button", 1252, 12, 228)
]

private func makeScreenPattern(_ size: CGSize, animation: Bool = false) -> CVPixelBuffer {
    let width = Int(size.width), height = Int(size.height)
    var result: CVPixelBuffer?
    let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
    precondition(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                     attributes, &result) == noErr)
    let pixels = result!
    CVPixelBufferLockBaseAddress(pixels, [])
    defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
    let luma = CVPixelBufferGetBaseAddressOfPlane(pixels, 0)!
    let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
    let chroma = CVPixelBufferGetBaseAddressOfPlane(pixels, 1)!
    memset(chroma, 128, CVPixelBufferGetBytesPerRowOfPlane(pixels, 1) * CVPixelBufferGetHeightOfPlane(pixels, 1))
    let ctx = CGContext(data: luma, width: width, height: height, bitsPerComponent: 8, bytesPerRow: lumaStride,
                        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    ctx.scaleBy(x: CGFloat(width) / 1280, y: CGFloat(height) / 800)
    func rect(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ tone: CGFloat) {
        ctx.setFillColor(gray: tone / 255, alpha: 1)
        ctx.fill(CGRect(x: x, y: y, width: w, height: h))
    }
    func label(_ string: String, x: CGFloat, y: CGFloat, size: CGFloat, dark: Bool = false) {
        let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let color = CGColor(gray: dark ? 0.16 : 0.91, alpha: 1)
        let attributes = [kCTFontAttributeName as NSAttributedString.Key: font,
                          kCTForegroundColorAttributeName as NSAttributedString.Key: color] as [NSAttributedString.Key: Any]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
        ctx.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, ctx)
    }
    rect(0, 0, 1280, 800, 38)
    rect(5, 5, 172, 790, 53)
    rect(192, 83, 1072, 640, 44)
    rect(192, 31, 1072, 42, 70)
    rect(192, 5, 110, 21, 98)
    rect(1200, 5, 64, 21, 228)
    rect(0, 794, 1280, 6, 135)
    rect(0, 0, 1280, 5, 200)
    rect(animation ? 580 : 520, 250, 180, 50, 195)
    rect(0, 5, 5, 789, 118)
    rect(1274, 5, 6, 789, 155)
    label("Remote session", x: 22, y: 753, size: 18)
    label("Full-screen test pattern", x: 205, y: 752, size: 25)
    label("The four border marks and all three controls below must be visible.", x: 208, y: 690, size: 19)
    label("Type a message", x: 207, y: 46, size: 15)
    label("Model", x: 248, y: 11, size: 12)
    label("Send", x: 1213, y: 11, size: 12, dark: true)
    return pixels
}

@available(macOS 14, *)
private func decodeScreenPattern(_ sample: CMSampleBuffer) -> CVPixelBuffer {
    var decoder: VTDecompressionSession?
    let attributes = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange] as CFDictionary
    precondition(VTDecompressionSessionCreate(allocator: nil, formatDescription: sample.formatDescription!,
                                               decoderSpecification: nil, imageBufferAttributes: attributes,
                                               outputCallback: nil, decompressionSessionOut: &decoder) == noErr)
    let session = decoder!
    defer { VTDecompressionSessionInvalidate(session) }
    let done = DispatchSemaphore(value: 0)
    var image: CVPixelBuffer?
    precondition(VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) {
        status, _, pixels, _, _ in
        if status == noErr { image = pixels }
        done.signal()
    } == noErr)
    VTDecompressionSessionWaitForAsynchronousFrames(session)
    precondition(done.wait(timeout: .now() + 4) == .success)
    return image!
}

// Test-only relay. It delays raw socket bytes in order, as a stalled TCP
// connection would, without reading message types or touching the live relay.
private final class TransportTestPath {
    private let hostListener: NWListener
    private let relayListener: NWListener
    private var bridge: [NWConnection] = []
    private var closed = false
    private var hostReady = false
    private var viewerReady = false
    private(set) var host: Wire?
    private(set) var viewer: Wire?
    private(set) var error: String?
    private(set) var downstreamReads = 0
    var holdDownstreamUntil: DispatchTime = .now()
    var ready: Bool { hostReady && viewerReady }

    init() throws {
        func listener() throws -> NWListener {
            let parameters = tcpParameters()
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            return try NWListener(using: parameters)
        }
        hostListener = try listener()
        relayListener = try listener()
    }

    func start() {
        hostListener.newConnectionHandler = { [weak self] connection in
            guard let self = self, !self.closed, self.host == nil else { connection.cancel(); return }
            let wire = Wire(connection, queue: .main)
            self.host = wire
            wire.onReady = { [weak self] in self?.hostReady = true }
            wire.onEnd = { [weak self] reason in self?.fail(reason) }
            wire.start()
        }
        hostListener.stateUpdateHandler = { [weak self] state in
            guard let self = self, !self.closed else { return }
            if case .ready = state { self.relayListener.start(queue: .main) }
            if case let .failed(error) = state { self.fail(error.localizedDescription) }
        }
        relayListener.stateUpdateHandler = { [weak self] state in
            guard let self = self, !self.closed else { return }
            if case .ready = state, let port = self.relayListener.port {
                let wire = Wire(NWConnection(to: loopback(port.rawValue), using: tcpParameters()), queue: .main)
                self.viewer = wire
                wire.onReady = { [weak self] in self?.viewerReady = true }
                wire.onEnd = { [weak self] reason in self?.fail(reason) }
                wire.start()
            }
            if case let .failed(error) = state { self.fail(error.localizedDescription) }
        }
        relayListener.newConnectionHandler = { [weak self] client in
            guard let self = self, !self.closed, self.bridge.isEmpty, let port = self.hostListener.port else {
                client.cancel()
                return
            }
            let host = NWConnection(to: loopback(port.rawValue), using: tcpParameters())
            self.bridge = [client, host]
            client.start(queue: .main)
            host.start(queue: .main)
            self.forward(client, to: host, downstream: false)
            self.forward(host, to: client, downstream: true)
        }
        hostListener.start(queue: .main)
    }

    private func fail(_ reason: String) {
        if !closed, error == nil { error = reason }
    }

    private func forward(_ source: NWConnection, to target: NWConnection, downstream: Bool) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, error in
            guard let self = self, !self.closed else { return }
            guard error == nil, let data = data, !data.isEmpty else {
                self.fail(error?.localizedDescription ?? "transport test socket closed")
                return
            }
            let arrival: DispatchTime = .now() + .milliseconds(25)
            let deadline = downstream ? max(arrival, self.holdDownstreamUntil) : arrival
            if downstream { self.downstreamReads += 1 }
            DispatchQueue.main.asyncAfter(deadline: deadline) { [weak self] in
                guard let self = self, !self.closed else { return }
                target.send(content: data, completion: .contentProcessed { [weak self] error in
                    guard let self = self, !self.closed else { return }
                    if let error = error { self.fail(error.localizedDescription) }
                    else { self.forward(source, to: target, downstream: downstream) }
                })
            }
        }
    }

    func stop() {
        closed = true
        hostListener.cancel()
        relayListener.cancel()
        host?.close()
        viewer?.close()
        for connection in bridge { connection.cancel() }
        bridge.removeAll()
    }
}

@available(macOS 14, *)
func runSeparatedTransportTest() -> Never {
    enum Condition: String, CaseIterable { case clear, videoStall, bothStall }
    struct Result {
        let inputArrival: Int
        let clickReceipt: Int
        let keyReceipt: Int
        let frameArrival: Int
    }

    func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }

    func median(_ values: [Int]) -> Int { values.sorted()[values.count / 2] }
    func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds / 1_000_000 }

    _ = NSApplication.shared
    let size = CGSize(width: 1280, height: 800)
    let idleFrame = makeScreenPattern(size)
    let updatedFrame = makeScreenPattern(size, animation: true)
    let display = DisplayInfo(id: 1, name: "Transport test screen", width: Int(size.width), height: Int(size.height))

    func trial(separate: Bool, condition: Condition) throws -> Result {
        let video = try TransportTestPath()
        let input = separate ? try TransportTestPath() : video
        video.start()
        if separate { input.start() }
        defer {
            video.stop()
            if separate { input.stop() }
        }

        func waitFor(_ label: String, until ready: () -> Bool) throws {
            let deadline = now() + 5_000
            while !ready() && now() < deadline {
                if let reason = video.error ?? input.error { throw StudioError.message(reason) }
                RunLoop.main.run(until: Date().addingTimeInterval(0.005))
            }
            guard ready() else { throw StudioError.message("timed out: \(label)") }
        }

        try waitFor("test sockets") { video.ready && input.ready }
        guard let videoHost = video.host, let videoViewer = video.viewer,
              let inputHost = input.host, let inputViewer = input.viewer else {
            throw StudioError.message("could not open test sockets")
        }
        let view = RemoteView(display: display, modifiers: MacModifierState())
        let capture = try Capture(info: display, retina: false, wire: videoHost, interactive: true)
        defer { capture.stop() }
        let actions: [Input] = [Input(action: .down, display: display.id, x: 0.5, y: 0.5),
                                Input(action: .up, display: display.id, x: 0.5, y: 0.5),
                                Input(action: .keyDown, display: display.id, a: kVK_ANSI_A),
                                Input(action: .keyUp, display: display.id, a: kVK_ANSI_A)]
        var observed: [Input] = []
        var observedAt: UInt64 = 0
        var receiptTimes: [(id: UInt32, time: UInt64)] = []
        var samples: [(sample: CMSampleBuffer, time: UInt64)] = []
        inputHost.onMessage = { kind, _, data in
            switch kind {
            case .input:
                if let input = try? JSONDecoder().decode(Input.self, from: data) {
                    observed.append(input)
                    observedAt = now()
                }
            case .keepAlive:
                // A probe after a button/key release confirms the host reached the input.
                inputHost.send(.keepAlive, data: data)
            default: require(false, "unexpected input channel packet")
            }
        }
        videoViewer.onMessage = { kind, _, data in
            switch kind {
            case .format: view.setFormat(data)
            case .video:
                if let sample = view.frame(data) { samples.append((sample, now())) }
            case .keepAlive where !separate: receiptTimes.append((data.number(at: 4), now()))
            default: require(false, "unexpected video channel packet")
            }
        }
        if separate {
            inputViewer.onMessage = { kind, _, data in
                require(kind == .keepAlive && data.count == 8, "control channel only returned receipts")
                receiptTimes.append((data.number(at: 4), now()))
            }
        }

        capture.start { error in require(error == nil, "test encoder starts") }
        capture.submitTestPattern(idleFrame)
        try waitFor("initial H.264 keyframe") { samples.count == 1 }
        let lastRead = video.downstreamReads
        let stallEnd: DispatchTime = .now() + .milliseconds(900)
        if condition != .clear { video.holdDownstreamUntil = stallEnd }
        if condition == .bothStall { input.holdDownstreamUntil = stallEnd }
        // Make the changed screen independently decodable after the simulated stall.
        capture.pauseForUpdate(true)
        capture.submitTestPattern(updatedFrame)
        capture.pauseForUpdate(false)
        try waitFor("updated screen entered the video socket") { video.downstreamReads > lastRead }

        var sent: [UInt32: UInt64] = [:]
        for (index, action) in actions.enumerated() {
            if index == 0 { sent[1] = now() }
            if index == 2 { sent[2] = now() }
            require(inputViewer.send(.input, data: try! JSONEncoder().encode(action)), "input queued")
            if index == 1 || index == 3 {
                var probe = Data()
                probe.put(0x434C494B)
                probe.put(UInt32((index + 1) / 2))
                require(inputViewer.send(.keepAlive, data: probe), "receipt probe queued")
            }
        }
        try waitFor("updated screen and both input receipts") { receiptTimes.count == 2 && samples.count == 2 }
        require(observed.map(\.action) == actions.map(\.action) && observed.map(\.a) == actions.map(\.a),
                "click and key down/up reached the sender once and in order")
        require(receiptTimes.map(\.id) == [1, 2], "receipts reached the receiver once and in order")
        require(samples[1].sample.formatDescription.map { CMFormatDescriptionGetMediaSubType($0) } == kCMVideoCodecType_H264,
                "video stayed H.264")
        let decoded = decodeScreenPattern(samples[1].sample)
        require(CVPixelBufferGetWidth(decoded) == display.width && CVPixelBufferGetHeight(decoded) == display.height,
                "the changed H.264 screen still decoded at 1280×800")
        if separate && condition == .videoStall {
            require(receiptTimes[1].time < samples[1].time, "control receipts overtook the stalled video socket")
        }
        return Result(inputArrival: Int(observedAt - sent[1]!),
                      clickReceipt: Int(receiptTimes[0].time - sent[1]!),
                      keyReceipt: Int(receiptTimes[1].time - sent[2]!),
                      frameArrival: Int(samples[1].time) - Int(sent[1]!))
    }

    do {
        print("H.264 1280×800, TCP loopback, 25 ms per direction, 900 ms simulated downstream stall.")
        print("All times in ms, median of 3 trials per mode. Receipts are not click-to-pixel measurements.")
        for condition in Condition.allCases {
            var shared: [Result] = []
            var separate: [Result] = []
            for index in 0..<3 {
                if index % 2 == 0 {
                    shared.append(try trial(separate: false, condition: condition))
                    separate.append(try trial(separate: true, condition: condition))
                } else {
                    separate.append(try trial(separate: true, condition: condition))
                    shared.append(try trial(separate: false, condition: condition))
                }
            }
            func report(_ mode: String, _ values: [Result]) {
                print("\(condition.rawValue) \(mode): input arrival \(median(values.map(\.inputArrival))), "
                      + "click receipt \(median(values.map(\.clickReceipt))), key receipt \(median(values.map(\.keyReceipt))), "
                      + "updated frame received \(median(values.map(\.frameArrival)))")
            }
            report("shared", shared)
            report("separate", separate)
            if condition == .videoStall {
                require(median(shared.map(\.clickReceipt)) - median(separate.map(\.clickReceipt)) > 400 &&
                        median(shared.map(\.keyReceipt)) - median(separate.map(\.keyReceipt)) > 400,
                        "separate control sockets avoid the simulated video stall")
            } else if condition == .bothStall {
                require(median(separate.map(\.clickReceipt)) > 500 && median(separate.map(\.keyReceipt)) > 500,
                        "separation cannot bypass a stall on both sockets")
            }
        }
        print("PASS: both input modes preserved click/key order and decoded the updated H.264 frame.")
        exit(0)
    } catch {
        fputs("FAIL: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}
