// Draws the 1024px Lectern icon: a wooden lectern holding an open book of colour-coded lines, on a dark squircle.
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

func gradient(_ colors: [Int]) -> CGGradient {
    CGGradient(colorsSpace: nil, colors: colors.map { rgb($0) } as CFArray, locations: nil)!
}

/// Fills a path with a vertical gradient, top colour first.
func fill(_ path: CGPath, _ colors: [Int], shadow: CGFloat = 0) {
    let box = path.boundingBox
    if shadow > 0 {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: shadow, color: CGColor(gray: 0, alpha: 0.5))
        ctx.addPath(path)
        ctx.setFillColor(rgb(colors.last!))
        ctx.fillPath()
        ctx.restoreGState()
    }
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.drawLinearGradient(gradient(colors), start: CGPoint(x: 0, y: box.maxY), end: CGPoint(x: 0, y: box.minY), options: [])
    ctx.restoreGState()
}

func rounded(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

// macOS icon grid: 824pt body centered on a 1024 canvas.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = rounded(body, 185)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: CGColor(gray: 0, alpha: 0.35))
ctx.addPath(shape)
ctx.setFillColor(.black)
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(shape)
ctx.clip()
ctx.drawLinearGradient(gradient([0x2b3a67, 0x0f1424]), start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])
let glow = CGGradient(colorsSpace: nil, colors: [rgb(0x5b8cff, 0.35), rgb(0x5b8cff, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 700), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 700), endRadius: 520, options: [])
ctx.restoreGState()

// Stand: a base and a column, in walnut.
fill(rounded(CGRect(x: 322, y: 196, width: 380, height: 56), 28), [0x8a5a3b, 0x5a3622], shadow: 30)
fill(rounded(CGRect(x: 466, y: 236, width: 92, height: 250), 20), [0x6e452c, 0x4a2c1b])
// Column highlight.
fill(rounded(CGRect(x: 482, y: 250, width: 18, height: 222), 9), [0x9a6a48, 0x7a4f33])

// Desk: the slanted top, seen from the front, so it's wider at the near (lower) edge.
let desk = CGMutablePath()
desk.move(to: CGPoint(x: 196, y: 500))
desk.addLine(to: CGPoint(x: 828, y: 500))
desk.addLine(to: CGPoint(x: 770, y: 790))
desk.addLine(to: CGPoint(x: 254, y: 790))
desk.closeSubpath()
fill(desk, [0x9c6844, 0x7a4b2e], shadow: 40)
// The front lip that holds the book.
fill(rounded(CGRect(x: 176, y: 452, width: 672, height: 62), 22), [0xa8724c, 0x6e432a])

// The open book: two pages bowing down towards the gutter.
let gutterX: CGFloat = 512
func pageOutline(left: Bool) -> CGPath {
    let s: CGFloat = left ? -1 : 1
    let p = CGMutablePath()
    p.move(to: CGPoint(x: gutterX, y: 512))
    p.addQuadCurve(to: CGPoint(x: gutterX + s * 286, y: 528), control: CGPoint(x: gutterX + s * 140, y: 540))
    p.addLine(to: CGPoint(x: gutterX + s * 244, y: 760))
    p.addQuadCurve(to: CGPoint(x: gutterX, y: 742), control: CGPoint(x: gutterX + s * 120, y: 790))
    p.closeSubpath()
    return p
}
for left in [true, false] {
    fill(pageOutline(left: left), left ? [0xeef2f8, 0xd9e0ec] : [0xf7f9fc, 0xe3e8f1], shadow: 16)
}
// Gutter shading.
ctx.saveGState()
ctx.addPath(pageOutline(left: true))
ctx.addPath(pageOutline(left: false))
ctx.clip()
let gutter = CGGradient(colorsSpace: nil, colors: [rgb(0x0f1424, 0), rgb(0x0f1424, 0.22), rgb(0x0f1424, 0)] as CFArray,
                        locations: [0, 0.5, 1])!
ctx.drawLinearGradient(gutter, start: CGPoint(x: gutterX - 40, y: 0), end: CGPoint(x: gutterX + 40, y: 0), options: [])
ctx.restoreGState()

// Code-like rows on each page: an indent, then coloured segments. Rows shorten a little towards the far edge.
func rows(left: Bool, _ lines: [(indent: CGFloat, segments: [(CGFloat, Int)])]) {
    var y: CGFloat = 690
    for (index, line) in lines.enumerated() {
        let scale = 0.86 + 0.03 * CGFloat(index)
        var x = (left ? gutterX - 236 : gutterX + 40) + 14 * (CGFloat(lines.count - index) / CGFloat(lines.count)) + line.indent
        for (length, color) in line.segments {
            let bar = CGRect(x: x, y: y, width: length * scale, height: 20)
            ctx.addPath(rounded(bar, 10))
            ctx.setFillColor(rgb(color))
            ctx.fillPath()
            x += length * scale + 14
        }
        y -= 38
    }
}
rows(left: true, [
    (0, [(44, 0xcf222e), (110, 0x0550ae)]),
    (28, [(76, 0x0550ae), (84, 0x0a9d44)]),
    (28, [(60, 0x0550ae), (56, 0xe07b00)]),
    (0, [(24, 0x8b97ad)]),
])
rows(left: false, [
    (0, [(52, 0xa626a4), (96, 0x0550ae)]),
    (28, [(120, 0x8b97ad)]),
    (28, [(70, 0x0550ae), (70, 0x0a9d44)]),
    (0, [(150, 0x8b97ad)]),
])

// A ribbon bookmark hanging from the gutter over the lip.
let ribbon = CGMutablePath()
ribbon.move(to: CGPoint(x: gutterX - 16, y: 520))
ribbon.addLine(to: CGPoint(x: gutterX + 16, y: 520))
ribbon.addLine(to: CGPoint(x: gutterX + 16, y: 398))
ribbon.addLine(to: CGPoint(x: gutterX, y: 414))
ribbon.addLine(to: CGPoint(x: gutterX - 16, y: 398))
ribbon.closeSubpath()
fill(ribbon, [0xe5484d, 0xb4232a], shadow: 8)

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
