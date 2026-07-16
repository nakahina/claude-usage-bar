import AppKit

let size = 1024
let canvas = NSImage(size: NSSize(width: size, height: size))
canvas.lockFocus()

let rect = NSRect(x: 0, y: 0, width: size, height: size)
let cornerRadius: CGFloat = CGFloat(size) * 0.224
let bgPath = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)

let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.85, green: 0.49, blue: 0.36, alpha: 1.0),
    NSColor(calibratedRed: 0.72, green: 0.33, blue: 0.22, alpha: 1.0),
])
gradient?.draw(in: bgPath, angle: -90)

let center = NSPoint(x: CGFloat(size) / 2, y: CGFloat(size) / 2)
let radius: CGFloat = CGFloat(size) * 0.27
let lineWidth: CGFloat = CGFloat(size) * 0.1

let track = NSBezierPath()
track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
track.lineWidth = lineWidth
NSColor.white.withAlphaComponent(0.28).setStroke()
track.stroke()

let progress = NSBezierPath()
progress.lineWidth = lineWidth
progress.lineCapStyle = .round
let sweep = 360.0 * 0.72
progress.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - sweep, clockwise: true)
NSColor.white.setStroke()
progress.stroke()

canvas.unlockFocus()

guard let tiff = canvas.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("PNG化に失敗しました")
}
let outputURL = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png")
try png.write(to: outputURL)
print("wrote \(outputURL.path)")
