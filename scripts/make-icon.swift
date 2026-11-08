// Generates an app icon (1024×1024 PNG) with Core Graphics and packages it
// into Resources/AppIcon.icns via `iconutil`.
import AppKit
import CoreGraphics

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "scripts/icon-build")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let size = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let S = CGFloat(size)

// Rounded-rect "squircle" body with a soft vertical gradient.
let inset: CGFloat = 64
let body = CGRect(x: inset, y: inset, width: S - inset * 2, height: S - inset * 2)
let radius: CGFloat = 190
let path = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

// Drop shadow
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 36, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.30))
ctx.addPath(path)
ctx.setFillColor(CGColor(red: 0.12, green: 0.16, blue: 0.26, alpha: 1))
ctx.fillPath()
ctx.setShadow(offset: .zero, blur: 0, color: nil)

// Gradient fill
ctx.saveGState()
ctx.addPath(path)
ctx.clip()
let gradient = CGGradient(colorsSpace: cs, colors: [
    CGColor(red: 0.22, green: 0.40, blue: 0.92, alpha: 1),
    CGColor(red: 0.42, green: 0.24, blue: 0.86, alpha: 1),
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: S), end: CGPoint(x: S, y: 0), options: [])

// Three photo cards, fanned out — one landscape, one square, one portrait.
func card(_ rect: CGRect, angle: CGFloat, fill: CGColor, accent: CGColor) {
    ctx.saveGState()
    ctx.translateBy(x: rect.midX, y: rect.midY)
    ctx.rotate(by: angle)
    let r = CGRect(x: -rect.width / 2, y: -rect.height / 2, width: rect.width, height: rect.height)
    let p = CGPath(roundedRect: r, cornerWidth: 34, cornerHeight: 34, transform: nil)
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 26, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.25))
    ctx.addPath(p)
    ctx.setFillColor(fill)
    ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    // "picture": a circle + a triangle mountain
    ctx.addPath(p)
    ctx.clip()
    ctx.setFillColor(accent)
    ctx.fillEllipse(in: CGRect(x: r.minX + 54, y: r.maxY - 150, width: 86, height: 86))
    let mountain = CGMutablePath()
    mountain.move(to: CGPoint(x: r.minX + 30, y: r.minY + 40))
    mountain.addLine(to: CGPoint(x: r.midX - 40, y: r.minY + r.height * 0.62))
    mountain.addLine(to: CGPoint(x: r.midX + 70, y: r.minY + 40))
    mountain.closeSubpath()
    mountain.move(to: CGPoint(x: r.midX + 40, y: r.minY + 40))
    mountain.addLine(to: CGPoint(x: r.maxX - 100, y: r.minY + r.height * 0.50))
    mountain.addLine(to: CGPoint(x: r.maxX - 25, y: r.minY + 40))
    mountain.closeSubpath()
    ctx.addPath(mountain)
    ctx.setFillColor(accent)
    ctx.fillPath()
    ctx.restoreGState()
}

let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
let soft = CGColor(red: 1, green: 1, blue: 1, alpha: 0.55)

// back card (portrait)
card(CGRect(x: 250, y: 250, width: 300, height: 470), angle: -0.16, fill: CGColor(red: 0.85, green: 0.88, blue: 0.98, alpha: 1), accent: CGColor(red: 0.22, green: 0.40, blue: 0.92, alpha: 0.45))
// square card
card(CGRect(x: 360, y: 300, width: 360, height: 360), angle: 0.05, fill: soft, accent: white)
// front card (landscape)
card(CGRect(x: 280, y: 330, width: 470, height: 310), angle: -0.05, fill: white, accent: CGColor(red: 0.42, green: 0.24, blue: 0.86, alpha: 0.75))

ctx.restoreGState()

// "size" ruler ticks along the bottom-right of the icon: the "classified by size" cue.
ctx.saveGState()
ctx.addPath(path)
ctx.clip()
ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.35))
ctx.setLineWidth(6)
ctx.setLineCap(.round)
for i in 0..<6 {
    let x = CGFloat(600 + i * 46)
    let len: CGFloat = i % 2 == 0 ? 46 : 26
    ctx.move(to: CGPoint(x: x, y: 150))
    ctx.addLine(to: CGPoint(x: x, y: 150 + len))
}
ctx.strokePath()
ctx.restoreGState()

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
let png = rep.representation(using: .png, properties: [:])!
let pngURL = outDir.appendingPathComponent("icon_1024.png")
try png.write(to: pngURL)
print(pngURL.path)
