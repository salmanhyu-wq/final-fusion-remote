import AppKit
import QuartzCore

// The graphics live on the receiver so a slow video stream cannot delay the click flash.
final class PointerFeedback {
    let layer = CALayer()
    private let ring = CAShapeLayer()
    private let hourglass = CALayer()
    private var point: CGPoint?
    private struct Receipt {
        let token: UInt32
        let sentAt: DispatchTime
    }

    private var pending: [Receipt] = []
    private var waitCheck: DispatchWorkItem?
    private var inputDelayed = false
    private var connectionDelayed = false
    private var showHourglass: Bool { inputDelayed || connectionDelayed }

    init() {
        layer.name = "pointer-feedback"
        ring.name = "click-ring"
        ring.fillColor = nil
        ring.strokeColor = NSColor.white.cgColor
        ring.lineWidth = 2
        ring.shadowColor = NSColor.black.cgColor
        ring.shadowOffset = .zero
        ring.shadowRadius = 1
        ring.shadowOpacity = 1
        ring.opacity = 0
        layer.addSublayer(ring)

        hourglass.name = "click-hourglass"
        hourglass.contents = Self.sandFrames.first
        hourglass.magnificationFilter = .nearest
        hourglass.shadowColor = NSColor.black.cgColor
        hourglass.shadowOpacity = 0.75
        hourglass.shadowRadius = 1
        hourglass.shadowOffset = .zero
        hourglass.isHidden = true
        layer.addSublayer(hourglass)
    }

    func layout(in bounds: CGRect) {
        layer.frame = bounds
        ring.frame = layer.bounds
        if showHourglass { positionHourglass() }
    }

    func move(to point: CGPoint?) {
        self.point = point
        if showHourglass { positionHourglass() }
    }

    func flash() {
        guard let point = point else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.path = CGPath(ellipseIn: CGRect(x: point.x - 7, y: point.y - 7, width: 14, height: 14),
                           transform: nil)
        CATransaction.commit()
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = 0.20
        ring.add(fade, forKey: "click")
    }

    func wait(for token: UInt32) {
        pending.append(Receipt(token: token, sentAt: .now()))
        if pending.count == 1 { checkWait() }
    }

    func received(_ token: UInt32) {
        // Each echo follows the covered inputs on the same ordered connection.
        guard let index = pending.firstIndex(where: { $0.token == token }) else { return }
        pending.removeFirst(index + 1)
        checkWait()
    }

    func setConnectionDelayed(_ delayed: Bool) {
        connectionDelayed = delayed
        positionHourglass()
    }

    func clear() {
        point = nil
        pending.removeAll()
        checkWait()
        ring.removeAllAnimations()
    }

    private func checkWait() {
        waitCheck?.cancel()
        waitCheck = nil
        let now = DispatchTime.now()
        pending.removeAll { $0.sentAt + .seconds(6) <= now }
        guard let oldest = pending.first else {
            inputDelayed = false
            positionHourglass()
            return
        }

        // Measure from the oldest unanswered probe. Overlapping fast responses
        // during continuous scrolling should not add up to a false warning.
        let showAt = oldest.sentAt + .milliseconds(180)
        if now >= showAt { inputDelayed = true }
        positionHourglass()
        let work = DispatchWorkItem { [weak self] in self?.checkWait() }
        waitCheck = work
        let nextCheck = inputDelayed ? oldest.sentAt + .seconds(6) : showAt
        DispatchQueue.main.asyncAfter(deadline: nextCheck, execute: work)
    }

    private func positionHourglass() {
        let bounds = layer.bounds
        let size = CGSize(width: 12, height: 14)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard showHourglass, let point = point, bounds.width >= size.width, bounds.height >= size.height else {
            hourglass.isHidden = true
            hourglass.removeAnimation(forKey: "sand")
            return
        }
        let right = point.x + 13
        let below = point.y - size.height - 5
        let x = right + size.width <= bounds.maxX ? right : point.x - size.width - 7
        let y = below >= bounds.minY ? below : point.y + 5
        hourglass.frame = CGRect(x: max(bounds.minX, min(x, bounds.maxX - size.width)).rounded(),
                                 y: max(bounds.minY, min(y, bounds.maxY - size.height)).rounded(),
                                 width: size.width, height: size.height)
        if hourglass.isHidden {
            hourglass.isHidden = false
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && Self.sandFrames.count > 1 {
                let sand = CAKeyframeAnimation(keyPath: "contents")
                sand.values = Self.sandFrames.map { $0 as Any }
                sand.calculationMode = .discrete
                sand.duration = 1.15
                sand.repeatCount = .infinity
                hourglass.add(sand, forKey: "sand")
            }
        }
    }

    // Original pixel artwork with a dark frame and light glass, readable on video.
    private static let sandFrames: [CGImage] = {
        let glass = [
            "############", "#++++++++++#", "##wwwwwwww##", ".#wwwwwwww#.",
            "..#wwwwww#..", "...#wwww#...", "....#ww#....", "....#ww#....",
            "...#wwww#...", "..#wwwwww#..", ".#wwwwwwww#.", "##wwwwwwww##",
            "#++++++++++#", "############"
        ]
        let space = CGColorSpaceCreateDeviceRGB()
        let colors: [Character: CGColor] = [
            "#": NSColor(white: 0.10, alpha: 1).cgColor,
            "+": NSColor(white: 0.84, alpha: 1).cgColor,
            "w": NSColor(srgbRed: 1.0, green: 0.97, blue: 0.86, alpha: 1).cgColor
        ]
        let gold = NSColor(srgbRed: 0.78, green: 0.51, blue: 0.13, alpha: 1).cgColor
        let sand: [[(Int, ClosedRange<Int>)]] = [
            [(3, 2...9), (4, 3...8), (5, 4...7), (6, 5...6), (8, 5...5), (11, 5...6)],
            [(4, 4...7), (5, 4...7), (6, 5...6), (7, 6...6), (9, 5...6), (10, 4...7), (11, 3...8)],
            [(7, 5...5), (8, 5...6), (9, 4...7), (10, 3...8), (11, 2...9)]
        ]
        return sand.compactMap { grains in
            guard let context = CGContext(data: nil, width: 12, height: 14, bitsPerComponent: 8,
                                          bytesPerRow: 0, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            for (row, line) in glass.enumerated() {
                for (column, character) in line.enumerated() {
                    if let color = colors[character] {
                        context.setFillColor(color)
                        context.fill(CGRect(x: column, y: 13 - row, width: 1, height: 1))
                    }
                }
            }
            context.setFillColor(gold)
            for (row, columns) in grains {
                context.fill(CGRect(x: columns.lowerBound, y: 13 - row, width: columns.count, height: 1))
            }
            return context.makeImage()
        }
    }()
}

/// The host's current cursor image, sent as `Kind.cursor`:
/// [version 1][pixels per point][hot spot x, UInt16][hot spot y, UInt16][PNG].
struct CursorShape: Equatable {
    static let maxPoints: CGFloat = 256
    let scale: UInt8
    let hotX: UInt16
    let hotY: UInt16
    let png: Data

    var bytes: Data {
        var data = Data([1, scale])
        data.append(contentsOf: [UInt8(hotX >> 8), UInt8(truncatingIfNeeded: hotX),
                                 UInt8(hotY >> 8), UInt8(truncatingIfNeeded: hotY)])
        data.append(png)
        return data
    }

    init(scale: UInt8, hotX: UInt16, hotY: UInt16, png: Data) {
        self.scale = scale
        self.hotX = hotX
        self.hotY = hotY
        self.png = png
    }

    init?(_ data: Data) {
        let bytes = [UInt8](data.prefix(6))
        guard bytes.count == 6, bytes[0] == 1, (1...4).contains(bytes[1]), data.count > 6, data.count <= 32768 else { return nil }
        scale = bytes[1]
        hotX = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
        hotY = UInt16(bytes[4]) << 8 | UInt16(bytes[5])
        png = Data(data.dropFirst(6))
    }

    /// Renders a cursor for sending, with a fingerprint so an unchanged cursor is not re-encoded.
    static func render(_ cursor: NSCursor, scale: CGFloat) -> (bitmap: NSBitmapImageRep, fingerprint: Int)? {
        let size = cursor.image.size
        guard size.width >= 1, size.height >= 1, size.width <= maxPoints, size.height <= maxPoints else { return nil }
        let width = Int(ceil(size.width * scale)), height = Int(ceil(size.height * scale))
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        cursor.image.draw(in: NSRect(x: 0, y: 0, width: width, height: height), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let pixels = bitmap.bitmapData else { return nil }
        var hasher = Hasher()
        hasher.combine(width)
        hasher.combine(height)
        hasher.combine(cursor.hotSpot.x)
        hasher.combine(cursor.hotSpot.y)
        hasher.combine(bytes: UnsafeRawBufferPointer(start: pixels, count: width * height * 4))
        return (bitmap, hasher.finalize())
    }

    /// Encodes the cursor at Retina scale, falling back to 1x when the PNG would exceed a wire message.
    static func encode(_ cursor: NSCursor, rendered: NSBitmapImageRep? = nil) -> CursorShape? {
        for scale in [2, 1] as [CGFloat] {
            guard let bitmap = scale == 2 ? (rendered ?? render(cursor, scale: 2)?.bitmap) : render(cursor, scale: 1)?.bitmap,
                  let png = bitmap.representation(using: .png, properties: [:]), png.count + 6 <= 32768 else { continue }
            let hot = cursor.hotSpot
            guard hot.x.isFinite, hot.y.isFinite, hot.x >= 0, hot.y >= 0 else { return nil }
            return CursorShape(scale: UInt8(scale), hotX: UInt16(min(65_535, (hot.x * scale).rounded())),
                               hotY: UInt16(min(65_535, (hot.y * scale).rounded())), png: png)
        }
        return nil
    }

    /// The receiver-side cursor, sized in points so it matches the host's cursor size.
    var cursor: NSCursor? {
        guard let bitmap = NSBitmapImageRep(data: png), bitmap.pixelsWide >= 1, bitmap.pixelsHigh >= 1 else { return nil }
        let points = NSSize(width: CGFloat(bitmap.pixelsWide) / CGFloat(scale), height: CGFloat(bitmap.pixelsHigh) / CGFloat(scale))
        guard points.width <= Self.maxPoints, points.height <= Self.maxPoints else { return nil }
        bitmap.size = points
        let image = NSImage(size: points)
        image.addRepresentation(bitmap)
        let hot = NSPoint(x: min(points.width - 1, CGFloat(hotX) / CGFloat(scale)),
                          y: min(points.height - 1, CGFloat(hotY) / CGFloat(scale)))
        return NSCursor(image: image, hotSpot: NSPoint(x: max(0, hot.x), y: max(0, hot.y)))
    }
}
