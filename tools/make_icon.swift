import AppKit
import CoreGraphics

// Renders the 1024x1024 Lumina app icon (run on macOS in CI).
let size = 1024
let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let space = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                          space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { exit(1) }

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [r, g, b, a])!
}
func radial(_ stops: [(CGFloat, CGColor)], center: CGPoint, radius: CGFloat) {
    let g = CGGradient(colorsSpace: space, colors: stops.map { $0.1 } as CFArray, locations: stops.map { $0.0 })!
    ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius,
                           options: [.drawsAfterEndLocation])
}

let c = CGPoint(x: 512, y: 512)
radial([(0, color(0.16, 0.18, 0.24)), (1, color(0.02, 0.02, 0.04))], center: CGPoint(x: 512, y: 600), radius: 900)

// Outer gold ring
ctx.setLineWidth(46)
ctx.setStrokeColor(color(0.98, 0.78, 0.25))
ctx.strokeEllipse(in: CGRect(x: 512 - 360, y: 512 - 360, width: 720, height: 720))

// Aperture blades
for i in 0..<6 {
    ctx.saveGState()
    ctx.translateBy(x: c.x, y: c.y)
    ctx.rotate(by: CGFloat(i) * .pi / 3)
    ctx.setFillColor(color(0.98, 0.78, 0.25, 0.16))
    ctx.move(to: CGPoint(x: 0, y: 0))
    ctx.addLine(to: CGPoint(x: 330, y: -60))
    ctx.addLine(to: CGPoint(x: 330, y: 190))
    ctx.closePath()
    ctx.fillPath()
    ctx.restoreGState()
}

// Glass
radial([(0, color(0.28, 0.45, 0.75)), (0.55, color(0.07, 0.12, 0.28)), (1, color(0.01, 0.02, 0.06))],
       center: CGPoint(x: 470, y: 560), radius: 250)
ctx.setBlendMode(.normal)
ctx.setFillColor(color(1, 1, 1, 0.0))
ctx.setLineWidth(10)
ctx.setStrokeColor(color(1, 1, 1, 0.18))
ctx.strokeEllipse(in: CGRect(x: 512 - 190, y: 512 - 190, width: 380, height: 380))

// Highlight
ctx.setFillColor(color(1, 1, 1, 0.55))
ctx.fillEllipse(in: CGRect(x: 420, y: 590, width: 90, height: 60))

guard let image = ctx.makeImage() else { exit(1) }
let rep = NSBitmapImageRep(cgImage: image)
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
