import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let space = CGColorSpaceCreateDeviceRGB()
let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
context.translateBy(x: 0, y: CGFloat(size))
context.scaleBy(x: 8, y: -8)

func color(_ rgb: UInt32) -> CGColor {
    CGColor(red: CGFloat((rgb >> 16) & 255) / 255,
            green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1)
}

func rounded(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h),
           cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func gradient(_ path: CGPath, _ from: UInt32, _ to: UInt32, _ a: CGPoint, _ b: CGPoint) {
    context.saveGState()
    context.addPath(path)
    context.clip()
    let colors = [color(from), color(to)] as CFArray
    let ramp = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1])!
    context.drawLinearGradient(ramp, start: a, end: b, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.restoreGState()
}

func stroke(_ path: CGPath, _ rgb: UInt32, width: CGFloat = 4) {
    context.addPath(path)
    context.setStrokeColor(color(rgb))
    context.setLineWidth(width)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.strokePath()
}

gradient(rounded(4, 4, 120, 120, 29), 0x633cc2, 0x1e143f, CGPoint(x: 4, y: 4), CGPoint(x: 124, y: 124))
let rear = rounded(38, 24, 65, 46, 8)
gradient(rear, 0x6446b0, 0x422771, CGPoint(x: 38, y: 24), CGPoint(x: 103, y: 70))
stroke(rear, 0xb9a0f2, width: 4.5)

let front = rounded(22, 40, 65, 47, 8)
gradient(front, 0x2d1b55, 0x1b1238, CGPoint(x: 22, y: 40), CGPoint(x: 87, y: 87))
stroke(front, 0xf4eaff, width: 5)

let foot = CGMutablePath()
foot.move(to: CGPoint(x: 44, y: 99)); foot.addLine(to: CGPoint(x: 65, y: 99))
foot.move(to: CGPoint(x: 54.5, y: 87)); foot.addLine(to: CGPoint(x: 54.5, y: 99))
stroke(foot, 0xf4eaff, width: 5)

let transfer = CGMutablePath()
transfer.move(to: CGPoint(x: 34, y: 57)); transfer.addLine(to: CGPoint(x: 72, y: 57))
transfer.move(to: CGPoint(x: 65, y: 50)); transfer.addLine(to: CGPoint(x: 72, y: 57))
transfer.addLine(to: CGPoint(x: 65, y: 64))
transfer.move(to: CGPoint(x: 72, y: 72)); transfer.addLine(to: CGPoint(x: 34, y: 72))
transfer.move(to: CGPoint(x: 41, y: 65)); transfer.addLine(to: CGPoint(x: 34, y: 72))
transfer.addLine(to: CGPoint(x: 41, y: 79))
stroke(transfer, 0x80f7d6, width: 4.8)

guard CommandLine.arguments.count == 2, let image = context.makeImage(),
      let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL,
                                                UTType.png.identifier as CFString, 1, nil) else { exit(1) }
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { exit(1) }
