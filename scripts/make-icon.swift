import AppKit

let destination = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)

func drawIcon(size: Int, filename: String) throws {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let scale = CGFloat(size) / 1024
    let transform = NSAffineTransform()
    transform.scale(by: scale)
    transform.concat()
    NSColor(srgbRed: 0.94, green: 0.93, blue: 0.96, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 62, y: 62, width: 900, height: 900), xRadius: 200, yRadius: 200).fill()

    NSColor(srgbRed: 0.75, green: 0.73, blue: 0.81, alpha: 0.36).setFill()
    NSBezierPath(roundedRect: NSRect(x: 316, y: 227, width: 400, height: 548), xRadius: 22, yRadius: 22).fill()
    NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 285, y: 249, width: 410, height: 558), xRadius: 20, yRadius: 20).fill()
    NSColor(srgbRed: 0.43, green: 0.39, blue: 0.53, alpha: 1).setStroke()
    let spine = NSBezierPath()
    spine.lineWidth = 5
    spine.move(to: NSPoint(x: 335, y: 271)); spine.line(to: NSPoint(x: 335, y: 785)); spine.stroke()
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    ("白" as NSString).draw(in: NSRect(x: 348, y: 441, width: 270, height: 240), withAttributes: [
        .font: NSFont(name: "Songti SC", size: 170) ?? NSFont.systemFont(ofSize: 170),
        .foregroundColor: NSColor(srgbRed: 0.32, green: 0.30, blue: 0.39, alpha: 1),
        .paragraphStyle: paragraph
    ])
    NSColor(srgbRed: 0.72, green: 0.70, blue: 0.78, alpha: 0.65).setStroke()
    for (y, end) in [(408.0, 593.0), (375.0, 554.0)] {
        let line = NSBezierPath()
        line.lineWidth = 5
        line.lineCapStyle = .round
        line.move(to: NSPoint(x: 406, y: y)); line.line(to: NSPoint(x: end, y: y)); line.stroke()
    }
    image.unlockFocus()
    let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: destination).appendingPathComponent(filename))
}

for size in [16, 32, 128, 256, 512] {
    try drawIcon(size: size, filename: "icon_\(size)x\(size).png")
    try drawIcon(size: size * 2, filename: "icon_\(size)x\(size)@2x.png")
}
