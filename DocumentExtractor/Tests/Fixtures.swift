import AppKit
import PDFKit

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
let document = PDFDocument()

let nativeData = NSMutableData()
var media = CGRect(x: 0, y: 0, width: 612, height: 792)
let consumer = CGDataConsumer(data: nativeData)!
let context = CGContext(consumer: consumer, mediaBox: &media, nil)!
context.beginPDFPage(nil)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
NSAttributedString(string: "Embedded project knowledge marker 24680", attributes: [
    .font: NSFont.systemFont(ofSize: 22), .foregroundColor: NSColor.black,
]).draw(at: NSPoint(x: 50, y: 650))
NSGraphicsContext.restoreGraphicsState()
context.endPDFPage()
context.closePDF()
document.insert(PDFDocument(data: nativeData as Data)!.page(at: 0)!, at: 0)

func scannedPage(_ text: String) -> PDFPage {
    let image = NSImage(size: NSSize(width: 1200, height: 1600))
    image.lockFocus()
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: 1200, height: 1600).fill()
    NSAttributedString(string: text, attributes: [
        .font: NSFont.systemFont(ofSize: 52), .foregroundColor: NSColor.black,
    ]).draw(at: NSPoint(x: 100, y: 1250))
    image.unlockFocus()
    return PDFPage(image: image)!
}

document.insert(scannedPage("Scanned invoice marker 12345"), at: 1)
let rotated = scannedPage("Rotated evidence marker 67890")
rotated.rotation = 90
document.insert(rotated, at: 2)
guard document.write(to: directory.appendingPathComponent("mixed.pdf")) else {
    fatalError("Could not write document fixture")
}
let large = PDFDocument()
for index in 0..<501 {
    large.insert(PDFDocument(data: nativeData as Data)!.page(at: 0)!, at: index)
}
large.write(to: directory.appendingPathComponent("page-limit.pdf"))
