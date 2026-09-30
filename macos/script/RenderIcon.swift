import AppKit

let destination = CommandLine.arguments[1]
let image = NSImage(size: NSSize(width: 1024, height: 1024))
image.lockFocus()
NSColor(calibratedRed: 0.08, green: 0.22, blue: 0.20, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 32, y: 32, width: 960, height: 960), xRadius: 216, yRadius: 216).fill()
for offset in [0, 110, 220] {
    let band = NSRect(x: 234, y: 255 + offset, width: 556, height: 280)
    NSColor(calibratedWhite: 1, alpha: offset == 220 ? 1 : 0.52).setStroke()
    let shape = NSBezierPath(roundedRect: band, xRadius: 48, yRadius: 48)
    shape.lineWidth = 30
    shape.stroke()
    NSColor(calibratedRed: 0.08, green: 0.22, blue: 0.20, alpha: 1).setFill()
    NSBezierPath(roundedRect: band.insetBy(dx: 19, dy: 19), xRadius: 30, yRadius: 30).fill()
}
NSColor.white.setFill()
NSBezierPath(roundedRect: NSRect(x: 303, y: 560, width: 236, height: 24), xRadius: 12, yRadius: 12).fill()
NSBezierPath(roundedRect: NSRect(x: 303, y: 505, width: 362, height: 24), xRadius: 12, yRadius: 12).fill()
image.unlockFocus()
guard let source = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: source),
      let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Icon rendering failed") }
try png.write(to: URL(fileURLWithPath: destination))
