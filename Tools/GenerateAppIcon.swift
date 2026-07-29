import AppKit

let destination = CommandLine.arguments.dropFirst().first ?? "LocusIcon-1024.png"
let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)

image.lockFocus()
guard let context = NSGraphicsContext.current?.cgContext else {
    fatalError("Unable to create drawing context")
}

context.setShouldAntialias(true)

let base = NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 224, yRadius: 224)
NSColor(calibratedRed: 0.075, green: 0.086, blue: 0.071, alpha: 1).setFill()
base.fill()

let fieldRect = NSRect(x: 92, y: 92, width: 840, height: 840)
let field = NSBezierPath(roundedRect: fieldRect, xRadius: 170, yRadius: 170)
NSColor(calibratedRed: 0.855, green: 0.965, blue: 0.424, alpha: 1).setFill()
field.fill()

let insetRect = NSRect(x: 136, y: 136, width: 752, height: 752)
let inset = NSBezierPath(roundedRect: insetRect, xRadius: 138, yRadius: 138)
NSColor(calibratedRed: 0.969, green: 0.949, blue: 0.886, alpha: 1).setFill()
inset.fill()

NSColor(calibratedRed: 0.075, green: 0.086, blue: 0.071, alpha: 1).setStroke()
for offset in [-86.0, 86.0] {
    let slash = NSBezierPath()
    slash.lineWidth = 82
    slash.lineCapStyle = .round
    slash.move(to: NSPoint(x: 420 + offset, y: 312))
    slash.line(to: NSPoint(x: 604 + offset, y: 712))
    slash.stroke()
}

image.unlockFocus()

guard
    let tiff = image.tiffRepresentation,
    let bitmap = NSBitmapImageRep(data: tiff),
    let png = bitmap.representation(using: .png, properties: [:])
else {
    fatalError("Unable to encode icon")
}

try png.write(to: URL(fileURLWithPath: destination))
