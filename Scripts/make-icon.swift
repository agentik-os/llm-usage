import AppKit
let output = CommandLine.arguments[1]
let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let tile = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 206, yRadius: 206)
NSGradient(colors: [NSColor(white: 0.99, alpha: 1), NSColor(white: 0.72, alpha: 1)])!.draw(in: tile, angle: -65)
NSColor.white.withAlphaComponent(0.8).setStroke()
tile.lineWidth = 7
tile.stroke()
let disc = NSBezierPath(ovalIn: NSRect(x: 229, y: 229, width: 566, height: 566))
NSColor.white.withAlphaComponent(0.6).setFill()
disc.fill()
let track = NSBezierPath()
track.appendArc(withCenter: NSPoint(x: 512, y: 512), radius: 279, startAngle: -135, endAngle: 135, clockwise: true)
track.lineWidth = 46
track.lineCapStyle = .round
NSColor(white: 0.1, alpha: 0.11).setStroke()
track.stroke()
let arc = NSBezierPath()
arc.appendArc(withCenter: NSPoint(x: 512, y: 512), radius: 279, startAngle: -135, endAngle: 28, clockwise: true)
arc.lineWidth = 46
arc.lineCapStyle = .round
NSColor(white: 0.12, alpha: 1).setStroke()
arc.stroke()
if let symbol = NSImage(systemSymbolName: "sparkle", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 196, weight: .light)) {
    let tinted = NSImage(size: symbol.size)
    tinted.lockFocus()
    symbol.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
    NSColor(white: 0.1, alpha: 1).setFill()
    NSRect(origin: .zero, size: symbol.size).fill(using: .sourceAtop)
    tinted.unlockFocus()
    tinted.draw(in: NSRect(x: 416, y: 416, width: 192, height: 192))
}
image.unlockFocus()
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
