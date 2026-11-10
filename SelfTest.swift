import AppKit
import Carbon.HIToolbox
import Foundation
import Network
import VideoToolbox

func runSelfTests() -> Never {
    func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }

    func checkDockUpdateIdentity() throws {
        let fm = FileManager.default
        let parent = fm.temporaryDirectory.appendingPathComponent("Studio-test-swap-" + UUID().uuidString)
        try fm.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: parent) }
        let application = parent.appendingPathComponent("Installed.app")
        let replacement = parent.appendingPathComponent("Replacement.app")
        for (url, marker) in [(application, "old"), (replacement, "new")] {
            let contents = url.appendingPathComponent("Contents")
            try fm.createDirectory(at: contents, withIntermediateDirectories: true)
            try Data(marker.utf8).write(to: contents.appendingPathComponent("test-marker"))
        }
        let identity = try fm.attributesOfItem(atPath: application.path)[.systemFileNumber] as! NSNumber
        let marker = application.appendingPathComponent("Contents/test-marker")
        check(ReceiverUpdateInstall.swapContents(of: application, with: replacement), "can install new contents")
        let updated = try fm.attributesOfItem(atPath: application.path)[.systemFileNumber] as! NSNumber
        let updatedText = try String(contentsOf: marker, encoding: .utf8)
        check(identity == updated && updatedText == "new", "update preserves the folder bookmarked by Dock")
        check(ReceiverUpdateInstall.swapContents(of: application, with: replacement), "can restore previous contents")
        let restoredText = try String(contentsOf: marker, encoding: .utf8)
        check(restoredText == "old", "failed launch can restore the previous app")
    }
    try! checkDockUpdateIdentity()

    let code = try! makeCode()
    check(decodeCode(hex(code)) == code, "pairing-code round trip")
    check(decodeCode("+1" + String(repeating: "00", count: 15)) == nil, "reject signed hexadecimal")
    check(!matches(code, Data(repeating: 0, count: 15)), "reject truncated secret")
    var other = code
    other[0] ^= 1
    check(!matches(code, other), "reject different secret")
    check(RelaySetup(relay: "https://studio.workers.dev").valid, "accept HTTPS relay")
    check(!RelaySetup(relay: "http://studio.workers.dev").valid, "reject unencrypted relay")
    check(!RelaySetup(relay: "https://fake@studio.workers.dev").valid, "reject relay credentials")
    check(!RelaySetup(relay: "https://studio.workers.dev/extra").valid, "reject relay path")

    let viewport = NSRect(x: 0, y: 0, width: 1280, height: 800)
    let video = NSSize(width: 1920, height: 1080)
    check(RemoteView.videoRect(in: viewport, videoSize: video).height == 720,
          "receiver never stretches a mismatched sender display")
    check(RemoteView.videoRect(in: viewport, videoSize: NSSize(width: 1680, height: 1050)) == viewport,
          "matching source aspect fills the viewport without stretching")
    let inset = RemoteView.videoRect(in: viewport, videoSize: NSSize(width: 1680, height: 1050), margin: 0.025)
    check(inset.minY == 20 && inset.maxY == 780 && inset.midX == viewport.midX,
          "the whole picture is centered with a small safe border")
    check(RemoteView.screenshotAction(key: UInt16(kVK_ANSI_3), flags: [.command, .shift]) == .screenshotFull &&
          RemoteView.screenshotAction(key: UInt16(kVK_ANSI_4), flags: [.command, .shift, .control]) == .screenshotArea &&
          RemoteView.screenshotAction(key: UInt16(kVK_ANSI_5), flags: [.command, .shift]) == .screenshotOptions &&
          RemoteView.screenshotAction(key: UInt16(kVK_ANSI_3), flags: [.command]) == nil,
          "Mac screenshot chords are routed without hijacking Command-number shortcuts")
    let localScreenshot: NSEvent.ModifierFlags = [.control, .option, .command]
    check(RemoteView.screenshotAction(key: UInt16(kVK_ANSI_3), flags: localScreenshot, compatibility: true) == .screenshotFull &&
          RemoteView.screenshotAction(key: UInt16(kVK_ANSI_4), flags: localScreenshot, compatibility: true) == .screenshotArea &&
          RemoteView.screenshotAction(key: UInt16(kVK_ANSI_3), flags: localScreenshot) == nil,
          "local screenshot chords work only when the receiver enables them")

    let currentRelease = ReceiverUpdateVersion("0.6.0")!
    let laterRelease = ReceiverUpdateVersion("0.10.0")!
    check(laterRelease > currentRelease && ReceiverUpdateVersion("0.06.0") == nil, "strict numeric update versions")
    let releasePayload = Data([1, 2, 3, 4])
    let offer = ReceiverUpdateOffer(version: laterRelease, payload: releasePayload)
    check(offer.isNewer(than: currentRelease) && !offer.isNewer(than: laterRelease), "receiver refuses same-version and older installs")
    var transfer = ReceiverUpdateDownload(offer: offer)
    check(transfer.append(Data([1, 2])) && !offer.matches(transfer.payload), "partial update cannot be installed")
    check(!transfer.append(Data([3, 4, 5])), "reject a chunk that overruns the declared update size")
    check(transfer.append(Data([3, 4])) && offer.matches(transfer.payload), "complete update matches the original checksum")
    check(!offer.matches(Data([1, 2, 3, 5])), "receiver rejects a modified update")
    let options = ReceiverDisplayOptions(width: 2560, height: 1600, matchDisplay: true, localCursor: true)!
    let decodedOptions = ReceiverDisplayOptions(options.bytes)
    check(decodedOptions?.width == 2560 && decodedOptions?.height == 1600 &&
          decodedOptions?.matchDisplay == true && decodedOptions?.localCursor == true, "receiver display handshake")
    check(options.hasMatchingAspect(width: 1680, height: 1050) &&
          !options.hasMatchingAspect(width: 1920, height: 1080), "display mode is matched to the receiver")
    check(ReceiverDisplayOptions(Data([4, 10, 0, 6, 64])) == nil, "unknown display options rejected")
    let tiers = ReceiverResolution.allCases.compactMap { $0.displayOptions(width: 1280, height: 800) }
    check(tiers.map(\.width) == [1280, 1440, 1680, 1680] && tiers.map(\.height) == [800, 900, 1050, 1050] &&
          tiers.allSatisfy { $0.matchDisplay && $0.width * 10 == $0.height * 16 },
          "pixel match uses the same fallback as high")
    let native = ReceiverNativePixels(width: 2880, height: 1800)!
    check(ReceiverNativePixels(native.bytes) == native && native.fitsSource(width: 2880, height: 1800) &&
          !native.fitsSource(width: 1680, height: 1050) && !native.fitsSource(width: 3840, height: 2160),
          "pixel match accepts native detail without enlarging or cropping the source")
    let pointRect = CGRect(x: 0, y: 0, width: 1440, height: 900)
    check(RemoteView.videoRect(in: pointRect, videoSize: native.size) == pointRect,
          "2880-by-1800 video fills a 1440-by-900 Retina viewport")
    for preset in ReceiverResolution.allCases {
        let widescreen = preset.displayOptions(width: 1366, height: 768)!
        check(widescreen.width * 768 == widescreen.height * 1366, "nonstandard aspect is not rounded away")
    }
    let region = ScreenshotRegion(first: CGPoint(x: 0.75, y: 0.5), last: CGPoint(x: 0.25, y: 0.25))
    check(region.pixels(in: CGSize(width: 1440, height: 900)) == CGRect(x: 360, y: 225, width: 720, height: 225),
          "sender screenshot crop matches the normalized receiver selection")
    let invalidRegion = ScreenshotRegion(first: .zero, last: CGPoint(x: 2, y: 0.5))
    check(invalidRegion.pixels(in: CGSize(width: 1440, height: 900)) == nil, "invalid screenshot selection is rejected")

    let receipt = VideoFeedback(receivedBytes: UInt64(UInt32.max) + 37, requestKeyframe: true)
    let decodedReceipt = VideoFeedback(receipt.bytes)
    check(decodedReceipt?.receivedBytes == receipt.receivedBytes && decodedReceipt?.requestKeyframe == true &&
          VideoFeedback(Data(repeating: 255, count: 9)) == nil, "validated video receipts carry 64-bit offsets")
    var delivery = VideoSendWindow()
    delivery.record(200_000, atMS: 100)
    check(delivery.hasRoom(bitrate: 9_000_000), "old receivers are not required to send video receipts")
    check(delivery.acknowledge(0, atMS: 101) != nil && !delivery.hasRoom(bitrate: 9_000_000),
          "end-to-end send window stops a backlog even after the local socket has accepted it")
    check(delivery.acknowledge(200_001, atMS: 120) == nil, "reject ACK beyond the bytes actually sent")
    check(delivery.acknowledge(200_000, atMS: 500)?.queueDelayMS == 0 && delivery.baseRoundTripMS == 400 &&
          delivery.hasRoom(bitrate: 9_000_000), "400ms base RTT is measured and not treated as congestion")
    delivery.record(150_000, atMS: 510)
    check(delivery.hasRoom(bitrate: 9_000_000), "long-distance healthy connections retain a working flight window")
    delivery.record(55_000, atMS: 520)
    check(!delivery.hasRoom(bitrate: 9_000_000), "large outstanding bursts wait for actual delivery")
    check(delivery.queueDelayWhileWaiting(atMS: 900) == 0 && delivery.queueDelayWhileWaiting(atMS: 1_360) == 450,
          "a late frame receipt measures excess delay without treating base RTT as a stall")
    check(delivery.acknowledge(350_000, atMS: 1_150)?.progressed == true &&
          delivery.hasRoom(bitrate: 9_000_000), "new receipts free space for the latest frame")
    let keys: [String: Any] = ["79": ["enabled": true, "value": ["parameters": [91, 33, 393216]]],
                               "81": ["enabled": false]]
    let previousSpace = ShortcutBinding.resolve(.spacePrevious, shortcuts: keys)
    check(previousSpace?.key == 33 && previousSpace?.flags == [.maskControl, .maskShift],
          "custom Spaces shortcut is honored")
    check(ShortcutBinding.resolve(.spaceNext, shortcuts: keys) == nil, "disabled Spaces shortcut stays disabled")
    check(ShortcutBinding.resolve(.missionControl, shortcuts: [:])?.key == kVK_UpArrow,
          "Mission Control uses the default shortcut when unconfigured")

    let shift = NSEvent.ModifierFlags.shift.rawValue
    let left = UInt16(kVK_Shift), right = UInt16(kVK_RightShift)
    let modifiers = MacModifierState()
    check(modifiers.update(key: left, flags: .init(rawValue: shift | 0x02)) == true, "left Shift pressed")
    check(modifiers.update(key: right, flags: .init(rawValue: shift | 0x06)) == true, "right Shift pressed")
    check(modifiers.update(key: left, flags: .init(rawValue: shift | 0x04)) == false,
          "left Shift can release while right Shift stays down")
    check(modifiers.update(key: right, flags: []) == false, "last Shift released")
    check(modifiers.update(key: UInt16(kVK_CapsLock), flags: .capsLock) == true &&
          modifiers.update(key: UInt16(kVK_CapsLock), flags: []) == false, "Caps Lock follows its latched state")
    _ = modifiers.update(key: left, flags: .shift)
    modifiers.clear()
    check(modifiers.update(key: left, flags: .shift) == true, "focus loss clears remembered modifiers")

    func scroll(_ y: Double, precise: Bool = true, inverted: Bool = false) -> ScrollMotion {
        ScrollMotion(horizontal: 0, vertical: y, coarseHorizontal: 0, coarseVertical: y / 8,
                     continuous: precise, invertedFromDevice: inverted)
    }
    var scrolling = SessionScroll()
    let normal = scrolling.makeEvent(scroll(-9), phase: 1, momentum: 0, source: nil).flatMap { NSEvent(cgEvent: $0) }
    check(normal?.scrollingDeltaY == -9 && normal?.hasPreciseScrollingDeltas == true && normal?.phase == .began,
          "trackpad scroll keeps the resolved direction and finger phase")
    let reverse = scrolling.makeEvent(scroll(9, inverted: true), phase: 4, momentum: 1, source: nil)
        .flatMap { NSEvent(cgEvent: $0) }
    check(reverse?.scrollingDeltaY == 9 && reverse?.momentumPhase == .began,
          "natural direction is not inverted again and momentum is preserved")
    let cancelled = scrolling.end(source: nil)
    check(cancelled?.getIntegerValueField(.scrollWheelEventMomentumPhase) == 3,
          "disconnect ends active momentum")
    check(scrolling.end(source: nil) == nil, "no duplicate cancellation")
    check(scrolling.makeEvent(scroll(0.6), phase: nil, momentum: nil, source: nil) == nil,
          "a fraction waits for the next sample")
    let fine = scrolling.makeEvent(scroll(0.6), phase: nil, momentum: nil, source: nil)
        .flatMap { NSEvent(cgEvent: $0) }
    check(fine?.scrollingDeltaY == 1, "fractional motion carries forward")
    let wheelEvent = scrolling.makeEvent(scroll(-2, precise: false), phase: nil, momentum: nil, source: nil)
        .flatMap { NSEvent(cgEvent: $0) }
    check(wheelEvent?.hasPreciseScrollingDeltas == false && wheelEvent?.scrollingDeltaY == -2,
          "wheel ticks remain separate from trackpad motion")
    check(scrolling.makeEvent(scroll(.infinity), phase: 1, momentum: 0, source: nil) == nil,
          "invalid scroll input is rejected")
    check(MacInputSource.validID("com.apple.inputmethod.Korean.2SetKorean") &&
          !MacInputSource.validID("../../layout"), "only keyboard input source identifiers are accepted")

    var swipe = TrackpadGestures()
    let fingers = [CGPoint(x: 0.4, y: 0.25), CGPoint(x: 0.5, y: 0.3), CGPoint(x: 0.6, y: 0.25)]
    check(swipe.update(fingers, at: 1, aspect: 0.65) == nil, "swipe anchors on contact")
    check(swipe.update(fingers.map { CGPoint(x: $0.x + 0.04, y: $0.y) }, at: 1.04, aspect: 0.65) == nil,
          "small moves are ignored")
    check(swipe.update(fingers.map { CGPoint(x: $0.x, y: $0.y + 0.09) }, at: 1.10, aspect: 0.65) == .missionControl,
          "three fingers up map to Mission Control")
    check(swipe.update(fingers.map { CGPoint(x: $0.x, y: $0.y + 0.35) }, at: 1.15, aspect: 0.65) == nil,
          "only one shortcut per touch sequence")

    var pinch = TrackpadPinch()
    let touchPair = [CGPoint(x: 0.35, y: 0.35), CGPoint(x: 0.55, y: 0.35)]
    check(pinch.update(touchPair) == nil, "pinch anchors on contact")
    check(pinch.update(touchPair.map { CGPoint(x: $0.x, y: $0.y + 0.2) }) == nil,
          "parallel finger movement scrolls instead of zooming")
    check(pinch.update([CGPoint(x: 0.28, y: 0.35), CGPoint(x: 0.62, y: 0.35)]) == .zoomIn,
          "spreading two fingers zooms in")
    check(pinch.update(touchPair) == .zoomOut, "moving two fingers together zooms out")

    func diagnostic(_ received: Int, _ submitted: Int) -> ReceiverDisplayDiagnostics {
        ReceiverDisplayDiagnostics(id: 1, localWidth: 1280, localHeight: 800, fillsScreen: true, localCursorHidden: true,
                                   receivedFrames: received, submittedFrames: submitted, pinchEvents: 0, multiTouchEvents: 0,
                                   gestureShortcuts: 0, nativeGestureEvents: 0, nativeGestures: 0)
    }
    var tuning = StreamTuning()
    tuning.update(mode: .auto, sample: diagnostic(120, 60))
    check(!tuning.reduced, "transient frame drops do not reduce quality")
    tuning.update(mode: .auto, sample: diagnostic(120, 60))
    check(tuning.load == .lowerFPS, "sustained decoder drops reduce the frame rate")
    for _ in 0..<3 { tuning.update(mode: .auto, sample: diagnostic(120, 120)) }
    check(tuning.reduced, "quality recovery is deliberately slower")
    tuning.update(mode: .auto, sample: diagnostic(120, 120))
    check(!tuning.reduced, "stable receiver restores quality")
    tuning.update(mode: .auto, sample: diagnostic(120, 120), roundTripMS: 25)
    tuning.update(mode: .auto, sample: diagnostic(120, 120), roundTripMS: 130)
    check(!tuning.reduced, "a single latency spike does not change quality")
    tuning.update(mode: .auto, sample: diagnostic(120, 120), roundTripMS: 120)
    check(tuning.load == .lighterVideo && tuning.load.frameRate(60) == 60 && tuning.load.bitRate(9_000_000) < 9_000_000,
          "sustained queue delay reduces bitrate before reducing the frame rate")
    tuning.observeNetwork(extraDelayMS: 110, blocked: true)
    tuning.observeNetwork(extraDelayMS: 110, blocked: true)
    check(tuning.load == .lowerFPS && tuning.load.frameRate(60) == 40,
          "persistent bandwidth pressure lowers frame rate only after bitrate")
    tuning.observeNetwork(extraDelayMS: 195, blocked: false)
    check(tuning.load.frameRate(60) == 30, "large queue delay drops directly to 30 fps")
    tuning.observeNetwork(extraDelayMS: 420, blocked: true)
    check(tuning.load.frameRate(60) == 20 && tuning.load.bitRate(6_000_000) == 1_500_000,
          "stalled delivery quickly lowers the rate to 20 fps")
    for _ in 0..<3 { tuning.observeNetwork(extraDelayMS: 10, blocked: false) }
    check(tuning.load.frameRate(60) == 20, "a brief improvement does not raise fps prematurely")
    tuning.observeNetwork(extraDelayMS: 10, blocked: false)
    check(tuning.load.frameRate(60) == 30, "recovery raises fps one step at a time")
    tuning.observeNetwork(extraDelayMS: 820, blocked: true)
    check(tuning.load.frameRate(60) == 20 && tuning.load.frameRate(30) == 20 &&
          tuning.load.bitRate(6_000_000) == 900_000,
          "severe congestion reduces bitrate while keeping a 20 fps target")
    for _ in 0..<4 { tuning.observeNetwork(extraDelayMS: 10, blocked: false) }
    check(tuning.load.frameRate(60) == 20, "the severe-stall mode recovers gradually")
    let now = Date()
    let session = UUID()
    let request = ReceiverResolutionRequest(id: UUID(), session: session, resolution: .low, issuedAt: now)
    check(request.canSend(to: ReceiverTuningStatus(session: session, resolution: .medium, allowed: true), now: now),
          "the current authorized receiver can be tuned")
    check(!request.canSend(to: ReceiverTuningStatus(session: session, resolution: .medium, allowed: false), now: now) &&
          !request.canSend(to: ReceiverTuningStatus(session: session, resolution: .medium, allowed: true),
                           now: now.addingTimeInterval(16)),
          "disabled and expired requests cannot be forwarded")
    tuning.update(mode: .smooth)
    check(tuning.reduced && tuning.load.frameRate(60) == 40, "manual smooth mode keeps its selected rate")
    tuning.update(mode: .sharp, sample: diagnostic(120, 60))
    check(!tuning.reduced, "manual sharp mode overrides auto reduction")
    check(!ReceiverDiagnostics(seconds: 6, displays: [diagnostic(20, 21)]).valid,
          "invalid receiver counters are rejected")

    let exitModifiers: NSEvent.ModifierFlags = [.control, .option, .command]
    check(ReceiverMode.isExitKey(UInt16(kVK_F12), flags: exitModifiers, fnDown: true), "exact kiosk exit chord")
    check(!ReceiverMode.isExitKey(UInt16(kVK_F12), flags: exitModifiers.union(.function), fnDown: false),
          "ordinary F12 function flag cannot exit without physical Fn")
    check(!ReceiverMode.isExitKey(UInt16(kVK_F12), flags: exitModifiers.union(.shift), fnDown: true),
          "extra Shift does not exit kiosk")
    check(!ReceiverMode.isExitKey(UInt16(kVK_F11), flags: exitModifiers, fnDown: true), "wrong key does not exit")

    let priorInput = Data(#"{"action":"scroll","display":1,"x":0.5,"y":0.5,"a":2,"b":0,"flags":0}"#.utf8)
    let decoded = try! JSONDecoder().decode(Input.self, from: priorInput)
    check(decoded.scrollPhase == nil && decoded.momentumPhase == nil && decoded.scrollMotion == nil &&
          decoded.keyboardType == nil && decoded.keyboardInputSource == nil, "older receiver input remains compatible")
    let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 2, wheel2: 0, wheel3: 0)!
    let eventData = StudioCopyEventData(wheel)!
    check(StudioCreateEvent(eventData)?.type == .scrollWheel, "public Core Graphics event round trip")
    check(!isRemoteGesture(.keyDown) && !isRemoteGesture(.scrollWheel), "gesture channel rejects keyboard and wheel")

    let queue = DispatchQueue(label: "studio-remote.self-test")
    let hostInput = Pipe()
    let clientInput = Pipe()
    let host = Wire(processInput: clientInput.fileHandleForWriting, processOutput: hostInput.fileHandleForReading, queue: queue)
    let client = Wire(processInput: hostInput.fileHandleForWriting, processOutput: clientInput.fileHandleForReading, queue: queue)
    let complete = DispatchSemaphore(value: 0)
    let pixels = Data(repeating: 0x68, count: 172_000)
    var expected = 0
    host.onMessage = { kind, _, payload in
        check(kind == .hello && matches(code, payload), "framed secret")
        check(host.send(.format, screen: 17, data: Data([1, 2, 3])), "send codec metadata")
        check(host.send(.video, screen: 17, data: pixels), "send frame larger than a pipe buffer")
        check(host.send(.receiverUpdate, screen: ReceiverUpdatePhase.chunk.rawValue, data: releasePayload),
              "send update chunk through the same transport")
        check(host.send(.keepAlive), "send empty frame")
    }
    client.onMessage = { kind, id, data in
        switch expected {
        case 0: check(kind == .format && id == 17 && data == Data([1, 2, 3]), "format framing")
        case 1: check(kind == .video && id == 17 && data == pixels, "frame fragmentation and display ID")
        case 2:
            check(kind == .receiverUpdate && id == ReceiverUpdatePhase.chunk.rawValue && data == releasePayload,
                  "update phases share the encrypted stream without changing video framing")
        case 3:
            check(kind == .keepAlive && data.isEmpty, "empty frame")
            complete.signal()
        default: check(false, "unexpected extra frame")
        }
        expected += 1
    }
    queue.async {
        host.start()
        client.start()
        check(!client.send(.input, data: Data(count: 32769)), "reject oversized control message")
        check(client.send(.hello, data: code), "send auth frame")
    }
    check(complete.wait(timeout: .now() + 5) == .success, "transport timed out")

    // Cursor shapes survive the wire format with their hot spot and point size.
    // Standard cursors are empty placeholders outside a running app, so draw two test cursors.
    func testCursor(_ size: CGFloat, hotSpot: NSPoint, fill: NSColor) -> NSCursor {
        NSCursor(image: NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            fill.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2)).fill()
            return true
        }, hotSpot: hotSpot)
    }
    let beam = testCursor(24, hotSpot: NSPoint(x: 12, y: 12), fill: .white)
    let hand = testCursor(32, hotSpot: NSPoint(x: 5, y: 1), fill: .systemPink)
    for (cursor, name) in [(beam, "round"), (hand, "large")] {
        guard let (bitmap, fingerprint) = CursorShape.render(cursor, scale: 2),
              let shape = CursorShape.encode(cursor, rendered: bitmap) else { check(false, "encode \(name) cursor"); continue }
        check(CursorShape.render(cursor, scale: 2)?.fingerprint == fingerprint, "stable \(name) cursor fingerprint")
        let decoded = CursorShape(shape.bytes)
        check(decoded == shape, "\(name) cursor wire round trip")
        let shown = decoded?.cursor
        check(shown.map { abs($0.hotSpot.x - cursor.hotSpot.x) <= 0.5 && abs($0.hotSpot.y - cursor.hotSpot.y) <= 0.5 } == true,
              "\(name) cursor hot spot")
        check(shown.map { abs($0.image.size.width - cursor.image.size.width) <= 1 } == true, "\(name) cursor size")
    }
    check(CursorShape.render(beam, scale: 2)?.fingerprint != CursorShape.render(hand, scale: 2)?.fingerprint,
          "different cursors have different fingerprints")
    check(CursorShape(Data([2, 2, 0, 0, 0, 0, 1])) == nil && CursorShape(Data([1, 9, 0, 0, 0, 0, 1])) == nil,
          "reject unknown cursor versions and scales")
    var optIn = Input(action: .cursorShapes, display: 1)
    optIn.sequence = 1
    check((try? JSONDecoder().decode(Input.self, from: JSONEncoder().encode(optIn)))?.action == .cursorShapes,
          "cursor opt-in input round trip")
    check(SymbolicHotKeys.available, "system shortcut mode functions are present")
    let shortcutMode = SymbolicHotKeys.mode
    let shortcutToken = SymbolicHotKeys.disable()
    check(shortcutToken != nil && SymbolicHotKeys.mode == SymbolicHotKeys.disabledMode,
          "receiver mode turns off this Mac's system shortcuts such as ⌘+Space")
    SymbolicHotKeys.restore(shortcutToken)
    check(SymbolicHotKeys.mode == shortcutMode, "leaving receiver mode restores system shortcuts")

    // Agent help: every guide is complete on its own and never carries secrets.
    let executable = AgentGuide.executable
    let setupGuide = AgentGuide.setup(), fixGuide = AgentGuide.fix(report: "{}")
    check(setupGuide.contains(executable) && setupGuide.contains("--set-relay") && setupGuide.contains("--start-sharing")
          && setupGuide.contains("--support-report"), "setup guide names the app and the agent commands")
    check(fixGuide.contains("--send-receiver-update") && fixGuide.contains(AgentGuide.sourceURL) && fixGuide.contains("build.sh"),
          "fix guide covers diagnosis, rebuild and pushing the viewer")
    for target in ViewerTarget.allCases {
        let guide = AgentGuide.viewer(target)
        check(guide.contains("--export-receivers") && guide.contains(target.rawValue) && guide.contains(target.file)
              && guide.contains(target.firstRun), "viewer guide for \(target.rawValue)")
        check(target.firstRun.contains(target.isMac ? "Studio Receiver" : ".exe"), "first-run steps for \(target.rawValue)")
    }
    let hostReport = SupportReport.host()
    check(hostReport["version"] as? String == AgentGuide.version && hostReport["relayConfigured"] is Bool,
          "support report carries version and relay state")
    let reportText = SupportReport.text(hostReport)
    check(!reportText.contains("\"room\"") && !reportText.contains("\"pin\"") && !reportText.contains("invitation"),
          "support report leaves out connection secrets")
    check(ReceiverUpdateVersion("0.9.9").map { $0 > ReceiverUpdateVersion("0.8.17")! } == true,
          "0.9.9 is newer than the viewers already handed out")
    let marker = "private-fixture"
    let shared = SupportReport.text(SupportReport.shareable([
        "relay": "https://private-fixture.invalid", "settingsFolder": "/home/" + marker,
        "appPath": "/home/" + marker + "/test.app",
        "host": ["screenRecording": true, "status": marker, "lastExport": ["path": marker]],
        "receiver": ["senderDisplays": [["name": marker, "width": 2560]],
                     "receiver": ["connectionPath": "direct", "roundTripMS": 7,
                                  "tuning": ["session": marker], "displays": [["localWidth": 2560, "name": marker]]]]
    ]))
    check(!shared.contains(marker) && shared.contains("2560") && shared.contains("direct") &&
          shared.contains("roundTripMS") && shared.contains("screenRecording"), "shareable diagnostics retain only safe fields")
    check(ReceiverUpdateVersion.current.map { $0 > ReceiverUpdateVersion("0.9.9")! } == true,
          "1.0.0 can update the previous private viewer")
    print("PASS: screen fitting, input events, update validation, pairing, transport, cursor shapes, system shortcut mode and agent guides")
    exit(0)
}

func runLoopbackTest() -> Never {
    if #available(macOS 14, *) {
        do {
            var wire: Wire?
            let host = try StudioHost { _ in }
            host.onReady = { port in
                guard wire == nil else { return }
                let connection = NWConnection(to: loopback(port), using: tcpParameters())
                let peer = Wire(connection, queue: .main)
                wire = peer
                peer.onReady = { [weak peer] in
                    peer?.send(.hello, data: Data(repeating: 0, count: 17))
                }
                peer.onMessage = { kind, _, data in
                    guard kind == .failure, String(decoding: data, as: UTF8.self).contains(L("접속 코드", "access code")) else {
                        fputs("FAIL: unauthenticated client received a protected message\n", stderr)
                        exit(1)
                    }
                    print("PASS: host loopback listener; incorrect pairing code refused before capture")
                    exit(0)
                }
                peer.start()
            }
            try host.start()
            let deadline = Date().addingTimeInterval(6)
            while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            withExtendedLifetime(host) {}
        } catch {
            fputs("FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
    fputs("FAIL: loopback listener or pairing rejection did not respond\n", stderr)
    exit(1)
}

func runVideoTest(width: Int = 2560, height: Int = 1600) -> Never {
    func fail(_ message: String) -> Never {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
    guard #available(macOS 14, *) else { fail("macOS 14 is required for the host encoder") }
    let encoder: VTCompressionSession
    do { encoder = try makeH264Encoder(width: width, height: height) }
    catch { fail(error.localizedDescription) }
    var buffer: CVPixelBuffer?
    let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
    let created = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                      attributes, &buffer)
    guard created == kCVReturnSuccess, let buffer = buffer else { fail("CVPixelBuffer: \(created)") }
    CVPixelBufferLockBaseAddress(buffer, [])
    for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
        if let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) {
            memset(base, plane == 0 ? 96 : 128,
                   CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane))
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    let finished = DispatchSemaphore(value: 0)
    let result = VTCompressionSessionEncodeFrame(encoder, imageBuffer: buffer, presentationTimeStamp: .zero,
                                                   duration: CMTime(value: 1, timescale: 30),
                                                   frameProperties: [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary,
                                                   infoFlagsOut: nil) { status, _, sample in
        guard status == noErr, let sample = sample, let format = sample.formatDescription,
              let block = sample.dataBuffer, CMBlockBufferGetDataLength(block) > 0 else {
            fail("H.264 encode callback: \(status)")
        }
        var decompressor: VTDecompressionSession?
        let created = VTDecompressionSessionCreate(allocator: nil, formatDescription: format,
                                                    decoderSpecification: nil, imageBufferAttributes: nil,
                                                    outputCallback: nil, decompressionSessionOut: &decompressor)
        guard created == noErr, let decompressor = decompressor else { fail("H.264 decoder: \(created)") }
        let decoded = VTDecompressionSessionDecodeFrame(decompressor, sampleBuffer: sample, flags: [],
                                                         infoFlagsOut: nil) { status, _, image, _, _ in
            guard status == noErr, let image = image, CVPixelBufferGetWidth(image) == width,
                  CVPixelBufferGetHeight(image) == height else { fail("H.264 decode callback: \(status)") }
            finished.signal()
        }
        guard decoded == noErr else { fail("H.264 decode: \(decoded)") }
        VTDecompressionSessionWaitForAsynchronousFrames(decompressor)
        VTDecompressionSessionInvalidate(decompressor)
    }
    guard result == noErr else { fail("H.264 encode: \(result)") }
    VTCompressionSessionCompleteFrames(encoder, untilPresentationTimeStamp: .invalid)
    guard finished.wait(timeout: .now() + 8) == .success else { fail("H.264 round trip timed out") }
    VTCompressionSessionInvalidate(encoder)
    print("PASS: VideoToolbox H.264 encode/decode at \(width)×\(height)")
    exit(0)
}
