// PrismWall 图标生成器 · 方案 A「光谱极简」
// 深空黑 squircle，白光射入棱镜，一道彩虹光谱展开渐隐于右缘
// 用法: swift Scripts/make-icon.swift [输出目录，默认 .build/icon]
import AppKit

let outDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1] : ".build/icon"

let size = 1024
let ctx = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8,
    bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)

let spectrumColors: [(CGFloat, NSColor)] = [
    (0.00, NSColor(red: 1.00, green: 0.23, blue: 0.19, alpha: 1)), // #ff3b30
    (0.20, NSColor(red: 1.00, green: 0.58, blue: 0.00, alpha: 1)), // #ff9500
    (0.40, NSColor(red: 1.00, green: 0.84, blue: 0.04, alpha: 1)), // #ffd60a
    (0.60, NSColor(red: 0.19, green: 0.82, blue: 0.35, alpha: 1)), // #30d158
    (0.80, NSColor(red: 0.04, green: 0.52, blue: 1.00, alpha: 1)), // #0a84ff
    (1.00, NSColor(red: 0.75, green: 0.35, blue: 0.95, alpha: 1)), // #bf5af2
]

// ---- 底板：macOS 标准 squircle + 深空黑渐变 ----
let squircle = CGRect(x: 88, y: 88, width: 848, height: 848)
let squirclePath = NSBezierPath(roundedRect: squircle, xRadius: 196, yRadius: 196)
squirclePath.addClip()

let bg = NSGradient(
    starting: NSColor(red: 0.13, green: 0.13, blue: 0.15, alpha: 1), // #212127
    ending: NSColor(red: 0.039, green: 0.039, blue: 0.055, alpha: 1) // #0a0a0e
)!
bg.draw(in: squirclePath, angle: -90)

// ---- 光谱扇形（顶点 596,512 → 右缘，三层柔光 + 锐利核心）----
let spectrumGradient = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: spectrumColors.map { $0.1.cgColor } as CFArray,
    locations: spectrumColors.map { $0.0 }
)!

func drawSpectrum(expand: CGFloat, alpha: CGFloat) {
    ctx.saveGState()
    let path = CGMutablePath()
    path.move(to: CGPoint(x: 596, y: 512))
    path.addLine(to: CGPoint(x: 1024, y: 656 + expand))
    path.addLine(to: CGPoint(x: 1024, y: 360 - expand))
    path.closeSubpath()
    ctx.addPath(path)
    ctx.clip()
    ctx.setAlpha(alpha)
    ctx.drawLinearGradient(
        spectrumGradient,
        start: CGPoint(x: 596, y: 512),
        end: CGPoint(x: 1024, y: 512),
        options: []
    )
    ctx.restoreGState()
}

// 柔光层（由外向内渐实，模拟高斯光晕）
drawSpectrum(expand: 56, alpha: 0.10)
drawSpectrum(expand: 40, alpha: 0.16)
drawSpectrum(expand: 26, alpha: 0.24)
drawSpectrum(expand: 14, alpha: 0.34)
// 锐利核心
drawSpectrum(expand: 0, alpha: 1.0)

// ---- 入射白光束（穿入棱镜左面）----
func beam(_ rect: CGRect, color: NSColor, radius: CGFloat, alpha: CGFloat) {
    ctx.setAlpha(alpha)
    ctx.setFillColor(color.cgColor)
    ctx.addPath(CGPath(
        roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil
    ))
    ctx.fillPath()
    ctx.setAlpha(1)
}
beam(CGRect(x: 88, y: 502, width: 330, height: 20),
     color: .white, radius: 10, alpha: 0.12)
beam(CGRect(x: 88, y: 506, width: 330, height: 12),
     color: .white, radius: 6, alpha: 0.95)

// ---- 棱镜（玻璃质感三角）----
let prism = NSBezierPath()
prism.move(to: CGPoint(x: 308, y: 384))
prism.line(to: CGPoint(x: 616, y: 384))
prism.line(to: CGPoint(x: 462, y: 640))
prism.close()

let glass = NSGradient(
    starting: NSColor.white.withAlphaComponent(0.20),
    ending: NSColor.white.withAlphaComponent(0.03)
)!
glass.draw(in: prism, angle: -90)
NSColor.white.withAlphaComponent(0.75).setStroke()
prism.lineWidth = 7
prism.stroke()

// ---- 轮廓微光 ----
NSGraphicsContext.restoreGraphicsState()
ctx.saveGState()
let outline = NSBezierPath(roundedRect: squircle, xRadius: 196, yRadius: 196)
NSColor.white.withAlphaComponent(0.10).setStroke()
outline.lineWidth = 3
outline.stroke()
ctx.restoreGState()

let master = ctx.makeImage()!

// ---- 输出 iconset 全尺寸 ----
let fileManager = FileManager.default
try? fileManager.createDirectory(
    atPath: outDir + "/PrismWall.iconset", withIntermediateDirectories: true
)
let scales: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
let masterImage = NSImage(cgImage: master, size: NSSize(width: 1024, height: 1024))
for (name, px) in scales {
    let scaled = NSImage(size: NSSize(width: px, height: px), flipped: false) { _ in
        NSGraphicsContext.current?.imageInterpolation = .high
        masterImage.draw(
            in: CGRect(x: 0, y: 0, width: px, height: px),
            from: CGRect(x: 0, y: 0, width: 1024, height: 1024),
            operation: .copy,
            fraction: 1
        )
        return true
    }
    guard let tiff = scaled.tiffRepresentation,
          let outRep = NSBitmapImageRep(data: tiff),
          let data = outRep.representation(using: .png, properties: [:])
    else { continue }
    try! data.write(to: URL(fileURLWithPath: "\(outDir)/PrismWall.iconset/\(name)"))
}
let rep = NSBitmapImageRep(cgImage: master)
try! (rep.representation(using: .png, properties: [:])!)
    .write(to: URL(fileURLWithPath: "\(outDir)/icon_1024_master.png"))

print("iconset 输出完成 → \(outDir)/PrismWall.iconset")
