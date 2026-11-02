// Draws the 1280×640 GitHub social preview: the icon, the name, a tagline and the main features.
// Usage: swift Icon/make_social_preview.swift <out.png>   (run from the repo root; it reads Icon/icon_1024.png)
import AppKit

let width = 1280, height = 640
let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)

func rgb(_ hex: Int, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

// The icon's navy background and glow.
let background = CGGradient(colorsSpace: nil, colors: [rgb(0x2b3a67).cgColor, rgb(0x0f1424).cgColor] as CFArray, locations: nil)!
ctx.drawLinearGradient(background, start: CGPoint(x: 0, y: height), end: CGPoint(x: 0, y: 0), options: [])
let glow = CGGradient(colorsSpace: nil, colors: [rgb(0x5b8cff, 0.28).cgColor, rgb(0x5b8cff, 0).cgColor] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 300, y: 380), startRadius: 0,
                       endCenter: CGPoint(x: 300, y: 380), endRadius: 560, options: [])

// The icon, left.
let icon = NSImage(contentsOfFile: "Icon/icon_1024.png")!
icon.draw(in: NSRect(x: 40, y: 100, width: 440, height: 440))

func text(_ string: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, at point: CGPoint, kern: CGFloat = 0) -> CGSize {
    let attributed = NSAttributedString(string: string, attributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color,
        .kern: kern,
    ])
    attributed.draw(at: point)
    return attributed.size()
}

let left: CGFloat = 520
_ = text("Lectern", size: 112, weight: .bold, color: .white, at: CGPoint(x: left - 4, y: 388), kern: -2)
_ = text("A native Mac editor for code and text", size: 36, weight: .regular, color: rgb(0xc9d3e6), at: CGPoint(x: left, y: 336))

// Feature chips, two rows, each tinted with a colour from the editor's palette.
let chips: [[(String, Int)]] = [
    [("Markdown + Mermaid", 0x5b8cff), ("JSON & YAML", 0x0a9d44), ("Git", 0xe07b00)],
    [("Terminal & SSH", 0xa626a4), ("Swift + AppKit", 0xcf222e), ("Open source", 0x8b97ad)],
]
var y: CGFloat = 248
for row in chips {
    var x = left
    for (label, color) in row {
        let font = NSFont.systemFont(ofSize: 24, weight: .medium)
        let labelSize = NSAttributedString(string: label, attributes: [.font: font]).size()
        let chip = NSRect(x: x, y: y, width: labelSize.width + 52, height: 46)
        let path = NSBezierPath(roundedRect: chip, xRadius: 23, yRadius: 23)
        rgb(color, 0.18).setFill()
        path.fill()
        rgb(color, 0.55).setStroke()
        path.lineWidth = 1.5
        path.stroke()
        let dot = NSRect(x: chip.minX + 18, y: chip.midY - 5, width: 10, height: 10)
        rgb(color).setFill()
        NSBezierPath(ovalIn: dot).fill()
        _ = text(label, size: 24, weight: .medium, color: .white, at: CGPoint(x: chip.minX + 36, y: chip.midY - labelSize.height / 2))
        x = chip.maxX + 14
    }
    y -= 62
}

_ = text("github.com/Acasa-Labs/lectern", size: 24, weight: .regular, color: rgb(0x8b97ad), at: CGPoint(x: left, y: 76))

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
