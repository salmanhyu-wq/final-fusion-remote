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

    var steps: [(NSAppearance.Name, String)] = [(.aqua, "light"), (.darkAqua, "dark")]
    func next() {
        guard !steps.isEmpty else {
            save(canvas, to: output.appendingPathComponent("waiting-screen.png"))
            print(output.path)
            exit(0)
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
