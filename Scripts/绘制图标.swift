import AppKit

// 使用矢量路径绘制图标，输出安装包所需的各个分辨率。
let output = CommandLine.arguments[1]
func render(size: Int, path: String) {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let scale = CGFloat(size) / 1024
    let transform = AffineTransform(scale: scale)
    (transform as NSAffineTransform).concat()
    let background = NSBezierPath(roundedRect: NSRect(x: 72, y: 72, width: 880, height: 880), xRadius: 190, yRadius: 190)
    NSColor(calibratedRed: 0.075, green: 0.13, blue: 0.24, alpha: 1).setFill()
    background.fill()
    let screen = NSBezierPath(roundedRect: NSRect(x: 220, y: 320, width: 584, height: 382), xRadius: 39, yRadius: 39)
    NSColor(calibratedRed: 0.88, green: 0.94, blue: 1, alpha: 1).setStroke()
    screen.lineWidth = 25
    screen.stroke()
    let base = NSBezierPath()
    base.move(to: NSPoint(x: 180, y: 282))
    base.line(to: NSPoint(x: 844, y: 282))
    base.lineWidth = 30
    base.lineCapStyle = .round
    base.stroke()
    let moon = NSBezierPath()
    moon.move(to: NSPoint(x: 564, y: 613))
    moon.curve(to: NSPoint(x: 585, y: 435), controlPoint1: NSPoint(x: 516, y: 555), controlPoint2: NSPoint(x: 522, y: 477))
    moon.curve(to: NSPoint(x: 446, y: 615), controlPoint1: NSPoint(x: 442, y: 390), controlPoint2: NSPoint(x: 363, y: 551))
    moon.curve(to: NSPoint(x: 564, y: 613), controlPoint1: NSPoint(x: 479, y: 641), controlPoint2: NSPoint(x: 529, y: 639))
    moon.close()
    NSColor(calibratedRed: 0.54, green: 0.80, blue: 1, alpha: 1).setFill()
    moon.fill()
    NSGraphicsContext.restoreGraphicsState()
    try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
}
for size in [16, 32, 128, 256, 512] {
    render(size: size, path: "\(output)/icon_\(size)x\(size).png")
    render(size: size * 2, path: "\(output)/icon_\(size)x\(size)@2x.png")
}
