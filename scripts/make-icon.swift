// Draws the app icon into an .iconset folder: swift scripts/make-icon.swift <out.iconset>
import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)

    // Rounded-square background (macOS icon grid: 824/1024 body).
    let inset = s * 100 / 1024
    let body = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let bg = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)
    NSGradient(starting: NSColor(red: 0.16, green: 0.20, blue: 0.32, alpha: 1),
               ending: NSColor(red: 0.07, green: 0.08, blue: 0.13, alpha: 1))!.draw(in: bg, angle: -90)

    // Photo: sky, sun, mountains.
    let photo = body.insetBy(dx: body.width * 0.17, dy: body.height * 0.22)
    let photoPath = NSBezierPath(roundedRect: photo, xRadius: photo.width * 0.06, yRadius: photo.width * 0.06)
    NSGraphicsContext.saveGraphicsState()
    photoPath.addClip()
    NSGradient(starting: NSColor(red: 0.98, green: 0.62, blue: 0.40, alpha: 1),
               ending: NSColor(red: 0.42, green: 0.55, blue: 0.95, alpha: 1))!.draw(in: photo, angle: 90)
    NSColor(red: 1, green: 0.93, blue: 0.70, alpha: 1).setFill()
    let r = photo.width * 0.09
    NSBezierPath(ovalIn: NSRect(x: photo.maxX - photo.width * 0.3, y: photo.maxY - photo.height * 0.38, width: 2 * r, height: 2 * r)).fill()
    let back = NSBezierPath()
    back.move(to: NSPoint(x: photo.minX + photo.width * 0.35, y: photo.minY))
    back.line(to: NSPoint(x: photo.minX + photo.width * 0.68, y: photo.minY + photo.height * 0.55))
    back.line(to: NSPoint(x: photo.maxX + photo.width * 0.1, y: photo.minY))
    NSColor(red: 0.20, green: 0.30, blue: 0.48, alpha: 1).setFill()
    back.fill()
    let front = NSBezierPath()
    front.move(to: NSPoint(x: photo.minX - photo.width * 0.1, y: photo.minY))
    front.line(to: NSPoint(x: photo.minX + photo.width * 0.32, y: photo.minY + photo.height * 0.65))
    front.line(to: NSPoint(x: photo.minX + photo.width * 0.8, y: photo.minY))
    NSColor(red: 0.12, green: 0.18, blue: 0.32, alpha: 1).setFill()
    front.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Left/right chevrons hinting at arrow-key browsing.
    NSColor(white: 1, alpha: 0.9).setStroke()
    for dir in [-1.0, 1.0] {
        let cx = dir < 0 ? body.minX + body.width * 0.085 : body.maxX - body.width * 0.085
        let h = body.height * 0.07
        let chevron = NSBezierPath()
        chevron.move(to: NSPoint(x: cx - dir * h * 0.5, y: body.midY + h))
        chevron.line(to: NSPoint(x: cx + dir * h * 0.5, y: body.midY))
        chevron.line(to: NSPoint(x: cx - dir * h * 0.5, y: body.midY - h))
        chevron.lineWidth = s * 0.022
        chevron.lineCapStyle = .round
        chevron.lineJoinStyle = .round
        chevron.stroke()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try render(size).write(to: outDir.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size * 2).write(to: outDir.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
