// Draws the 1024px Lectern icon: two stacked pages with colour-coded lines on a dark squircle.
// Usage: swift Icon/make_icon.swift <out.png>
import AppKit

let size: CGFloat = 1024
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func rgb(_ hex: Int, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

// macOS icon grid: 824pt body centered on a 1024 canvas.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: CGColor(gray: 0, alpha: 0.35))
ctx.addPath(shape)
ctx.setFillColor(.black)
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(shape)
ctx.clip()
let background = CGGradient(colorsSpace: nil, colors: [rgb(0x2b3a67), rgb(0x0f1424)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(background, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])
let glow = CGGradient(colorsSpace: nil, colors: [rgb(0x5b8cff, 0.35), rgb(0x5b8cff, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 360, y: 760), startRadius: 0,
                       endCenter: CGPoint(x: 360, y: 760), endRadius: 520, options: [])
ctx.restoreGState()

/// A page with a folded top-right corner, drawn around its own centre and rotated.
func page(center: CGPoint, angle: CGFloat, fill: CGColor, rows: [(indent: CGFloat, segments: [(CGFloat, Int)])], shadow: CGFloat) {
    let w: CGFloat = 470, h: CGFloat = 590, fold: CGFloat = 96, r: CGFloat = 34
    ctx.saveGState()
    ctx.translateBy(x: center.x, y: center.y)
    ctx.rotate(by: angle)
    let left = -w / 2, right = w / 2, bottom = -h / 2, top = h / 2

    let outline = CGMutablePath()
    outline.move(to: CGPoint(x: left + r, y: bottom))
    outline.addLine(to: CGPoint(x: right - r, y: bottom))
    outline.addArc(tangent1End: CGPoint(x: right, y: bottom), tangent2End: CGPoint(x: right, y: bottom + r), radius: r)
    outline.addLine(to: CGPoint(x: right, y: top - fold))
    outline.addLine(to: CGPoint(x: right - fold, y: top))
    outline.addLine(to: CGPoint(x: left + r, y: top))
    outline.addArc(tangent1End: CGPoint(x: left, y: top), tangent2End: CGPoint(x: left, y: top - r), radius: r)
    outline.addLine(to: CGPoint(x: left, y: bottom + r))
    outline.addArc(tangent1End: CGPoint(x: left, y: bottom), tangent2End: CGPoint(x: left + r, y: bottom), radius: r)
    outline.closeSubpath()

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: shadow, color: CGColor(gray: 0, alpha: 0.45))
    ctx.addPath(outline)
    ctx.setFillColor(fill)
    ctx.fillPath()
    ctx.restoreGState()

    // Folded corner.
    let corner = CGMutablePath()
    corner.move(to: CGPoint(x: right - fold, y: top))
    corner.addLine(to: CGPoint(x: right - fold, y: top - fold + 18))
    corner.addQuadCurve(to: CGPoint(x: right - fold + 18, y: top - fold), control: CGPoint(x: right - fold, y: top - fold))
    corner.addLine(to: CGPoint(x: right, y: top - fold))
    corner.closeSubpath()
    ctx.addPath(corner)
    ctx.setFillColor(rgb(0xc9d3e6))
    ctx.fillPath()

    // Code-like rows: an indent, then coloured segments (e.g. a key and its value).
    var y = top - 140
    for row in rows {
        var x = left + 58 + row.indent
        for (length, color) in row.segments {
            let bar = CGRect(x: x, y: y, width: length, height: 30)
            ctx.addPath(CGPath(roundedRect: bar, cornerWidth: 15, cornerHeight: 15, transform: nil))
            ctx.setFillColor(rgb(color))
            ctx.fillPath()
            x += length + 22
        }
        y -= 62
    }
    ctx.restoreGState()
}

// Back page, tilted left and plain.
page(center: CGPoint(x: 458, y: 522), angle: 0.13, fill: rgb(0xa9b6d3), rows: [], shadow: 30)
// Front page with colour-coded "code", in the editor's palette.
page(center: CGPoint(x: 560, y: 500), angle: -0.06, fill: rgb(0xf7f9fc), rows: [
    (0, [(70, 0xcf222e), (150, 0x0550ae)]),
    (44, [(110, 0x0550ae), (150, 0x0a9d44)]),
    (44, [(90, 0x0550ae), (80, 0xe07b00)]),
    (44, [(130, 0x0550ae), (110, 0xa626a4)]),
    (0, [(40, 0x8b97ad)]),
    (0, [(250, 0x8b97ad)]),
], shadow: 40)

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
