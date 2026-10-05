import AppKit

func render(_ size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    let r = CGRect(x: 0, y: 0, width: size, height: size)

    // Rounded-rect app surface with a vertical gradient.
    let inset = size * 0.055
    let body = r.insetBy(dx: inset, dy: inset)
    let radius = size * 0.225
    let path = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    let colors = [NSColor(srgbRed: 0.18, green: 0.42, blue: 0.95, alpha: 1).cgColor,
                  NSColor(srgbRed: 0.36, green: 0.22, blue: 0.86, alpha: 1).cgColor]
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: colors as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: body.maxY),
                           end: CGPoint(x: 0, y: body.minY), options: [])
    // Soft highlight across the top third.
    ctx.setFillColor(NSColor.white.withAlphaComponent(0.13).cgColor)
    ctx.fill(CGRect(x: body.minX, y: body.midY + body.height * 0.10,
                    width: body.width, height: body.height * 0.40))
    ctx.restoreGState()

    // Three stacked caption bars — the product's core idea, three tracks at once.
    let barH = size * 0.072
    let gap = size * 0.052
    let widths: [CGFloat] = [0.56, 0.44, 0.50]
    let alphas: [CGFloat] = [1.0, 0.80, 0.60]
    let totalH = barH * 3 + gap * 2
    var y = body.midY - totalH / 2 - size * 0.035
    for i in (0..<3).reversed() {
        let w = body.width * widths[i]
        let bar = CGRect(x: body.midX - w / 2, y: y, width: w, height: barH)
        ctx.setFillColor(NSColor.white.withAlphaComponent(alphas[i]).cgColor)
        ctx.addPath(CGPath(roundedRect: bar, cornerWidth: barH / 2,
                           cornerHeight: barH / 2, transform: nil))
        ctx.fillPath()
        y += barH + gap
    }

    img.unlockFocus()
    return img
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let sizes: [(Int, Int)] = [(16,1),(16,2),(32,1),(32,2),(128,1),(128,2),(256,1),(256,2),(512,1),(512,2)]
for (pt, scale) in sizes {
    let px = CGFloat(pt * scale)
    let image = render(px)
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { continue }
    let name = scale == 1 ? "icon_\(pt)x\(pt).png" : "icon_\(pt)x\(pt)@2x.png"
    try? png.write(to: out.appendingPathComponent(name))
}
print("wrote iconset to \(out.path)")
