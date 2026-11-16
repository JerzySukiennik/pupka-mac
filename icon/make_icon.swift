// Draws the Pupka app icon (clay tile with a sheet of paper) at 1024 px and writes it as PNG.
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func color(_ hex: Int, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: a)
}

let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: tile, xRadius: 186, yRadius: 186)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x3a1c10, 0.35).cgColor)
color(0xc96442).setFill()
shape.fill()
ctx.restoreGState()
NSGradient(colors: [color(0xd77a55), color(0xc96442), color(0xb5532f)])!.draw(in: shape, angle: -90)
ctx.saveGState()
shape.addClip()
NSGradient(colors: [color(0xffffff, 0.22), color(0xffffff, 0)])!.draw(in: NSRect(x: 100, y: 560, width: 824, height: 364), angle: -90)
ctx.restoreGState()

ctx.saveGState()
ctx.translateBy(x: 512, y: 512)
ctx.rotate(by: 0.07)
let sheet = NSRect(x: -226, y: -268, width: 452, height: 536)
let paper = NSBezierPath(roundedRect: sheet, xRadius: 46, yRadius: 46)
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: color(0x3a1c10, 0.38).cgColor)
color(0xfffefb).setFill()
paper.fill()
ctx.setShadow(offset: .zero, blur: 0, color: nil)
color(0xc96442).setStroke()
for (i, w) in [300.0, 300.0, 176.0].enumerated() {
    let y = 118.0 - Double(i) * 112.0
    let line = NSBezierPath()
    line.lineWidth = 38
    line.lineCapStyle = .round
    line.move(to: NSPoint(x: -150, y: y))
    line.line(to: NSPoint(x: -150 + w, y: y))
    line.stroke()
}
ctx.restoreGState()
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
