import AppKit

/// `--preview-ui <folder>` saves the settings window and the receiver waiting screen as PNG files
/// in light and dark appearance without connecting, sending or changing any saved setting.
func runUIPreview(output: URL) {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let studio = StudioApp()
    let settings = studio.makePreviewWindow()
    let waiting = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                           styleMask: [.borderless], backing: .buffered, defer: false)
    waiting.backgroundColor = .black
    let canvas = ReceiverCanvas(frame: NSRect(x: 0, y: 0, width: 1280, height: 800))
    waiting.contentView = canvas
    canvas.setStatus(L("연결이 끊겼어요. 인터넷 연결을 확인하고, 보내는 맥이 보내기 중인지 살펴보세요. 자동으로 다시 연결해요.",
                       "The connection dropped. Check your internet and make sure the host Mac is sharing. Reconnecting automatically."))
    canvas.setActivity(.busy)
    waiting.setFrameOrigin(NSPoint(x: 0, y: 0))
    waiting.orderBack(nil)
    settings.orderFrontRegardless()

    // The explanation a “?” beside a setting opens, as its popover shows it.
    let bubble = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
    let note = HelpBubble.content(L("멀리 있는 맥에서 나는 소리(영상, 음악, 알림)를 이 컴퓨터에서 들어요. 그동안 멀리 있는 맥에서는 소리가 나지 않아요.",
                                    "Hear the far-away Mac's sound (videos, music, alerts) on this computer. Meanwhile the far-away Mac itself stays silent."))
    note.wantsLayer = true
    bubble.contentView = note
    bubble.setContentSize(note.fittingSize)
    bubble.setFrameOrigin(NSPoint(x: 0, y: 900))
    bubble.orderBack(nil)

    var steps: [(NSAppearance.Name, String)] = [(.aqua, "light"), (.darkAqua, "dark")]
    func next() {
        guard !steps.isEmpty else {
            save(canvas, to: output.appendingPathComponent("waiting-screen.png"))
            save(note, to: output.appendingPathComponent("help-bubble.png"))
            // Click the first “?” twice: it must open its note, then close it.
            func firstBubble(in view: NSView) -> HelpBubble? {
                guard !view.isHidden else { return nil }
                return (view as? HelpBubble) ?? view.subviews.lazy.compactMap { firstBubble(in: $0) }.first
            }
            guard let help = settings.contentView.flatMap({ firstBubble(in: $0) }) else {
                print("help bubbles: none found")
                exit(1)
            }
            help.performClick(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                // Wide enough to read, and no taller than a few lines.
                let size = help.openSize ?? .zero
                let readable = size.width >= 150 && size.width <= 300 && size.height >= 30 && size.height <= 160
                help.performClick(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    print("help bubble opens on a click at \(Int(size.width))×\(Int(size.height)): \(readable), closes on the next: \(!help.isOpen)")
                    print(output.path)
                    exit(readable && !help.isOpen ? 0 : 1)
                }
            }
            return
        }
        let (appearance, name) = steps.removeFirst()
        settings.appearance = NSAppearance(named: appearance)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            if let view = (settings.contentView as? NSScrollView)?.documentView ?? settings.contentView {
                save(view, to: output.appendingPathComponent("settings-\(name).png"))
            }
            next()
        }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { next() }
    app.run()
}

private func save(_ view: NSView, to url: URL) {
    view.layoutSubtreeIfNeeded()
    view.displayIfNeeded()
    let scale = view.window?.backingScaleFactor ?? 2
    let size = view.bounds.size
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                                     pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: rep) else { return }
    let cg = context.cgContext
    cg.scaleBy(x: scale, y: scale)
    if view.isFlipped {
        cg.translateBy(x: 0, y: size.height)
        cg.scaleBy(x: 1, y: -1)
    }
    view.effectiveAppearance.performAsCurrentDrawingAppearance {
        cg.setFillColor((view.window?.backgroundColor ?? .windowBackgroundColor).cgColor)
        cg.fill(CGRect(origin: .zero, size: size))
    }
    view.layer?.render(in: cg)
    try? rep.representation(using: .png, properties: [:])?.write(to: url)
}
