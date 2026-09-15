// DMG 背景图渲染：720×440pt 窗口的 @2x 背景图（1440×880 像素，144 DPI）
// 设计与图标摆放坐标一一对应——App 图标中心 (205,300)、Applications 中心 (515,300)（窗口坐标，原点左上）
// 用法: swift Scripts/make-dmg-background.swift <输出.png>
import AppKit

guard CommandLine.arguments.count == 2 else {
    print("用法: swift Scripts/make-dmg-background.swift <输出.png>"); exit(1)
}
let out = CommandLine.arguments[1]

let W = 1440, H = 880
// 直接在 1:1 像素位图上下文绘制——NSImage.lockFocus 在 Retina 下会 2x 背衬，导致输出尺寸翻倍
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                           isPlanar: false, colorSpaceName: .calibratedRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: W, height: H)
NSGraphicsContext.saveGraphicsState()
let ctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = ctx
defer { NSGraphicsContext.restoreGraphicsState() }

NSColor(calibratedRed: 245/255, green: 245/255, blue: 247/255, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: W, height: H).fill()

func rounded(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    let d = base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor
    return NSFont(descriptor: d, size: size) ?? base
}

// 水印装饰：SF Symbols 线稿，低透明度散布四周
func tinted(_ image: NSImage, alpha: CGFloat) -> NSImage {
    let out = NSImage(size: image.size)
    out.lockFocus()
    image.draw(in: NSRect(origin: .zero, size: image.size))
    let tintCtx = NSGraphicsContext.current!
    tintCtx.compositingOperation = .sourceIn
    NSColor.black.withAlphaComponent(alpha).setFill()
    tintCtx.cgContext.fill(NSRect(origin: .zero, size: image.size))
    out.unlockFocus()
    return out
}

let marks: [(String, NSPoint, CGFloat, CGFloat)] = [
    ("photo",           NSPoint(x: 170, y: H-190), 130,  7),
    ("play.rectangle",  NSPoint(x: W-180, y: H-200), 130, -6),
    ("heart",           NSPoint(x: 140, y: 190), 105, -9),
    ("square.grid.2x2", NSPoint(x: W-150, y: 180), 115,  5),
    ("magnifyingglass", NSPoint(x: W-130, y: H/2+30), 92,  0),
    ("sparkles",        NSPoint(x: 130, y: H/2+70), 92, 12),
]
for (name, p, size, angle) in marks {
    var sym = NSImage(systemSymbolName: name, accessibilityDescription: nil)!
    sym = sym.withSymbolConfiguration(.init(pointSize: size, weight: .light))!
    let t = tinted(sym, alpha: 0.055)
    let tr = NSAffineTransform()
    tr.translateX(by: p.x, yBy: p.y)
    tr.rotate(byDegrees: angle)
    tr.translateX(by: -t.size.width/2, yBy: -t.size.height/2)
    tr.concat()
    t.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
    tr.invert()
    tr.concat()
}

// 标题 + 副标语
let para = NSMutableParagraphStyle(); para.alignment = .center
NSAttributedString(string: "PrismWall", attributes: [
    .font: rounded(96, .heavy),
    .foregroundColor: NSColor(calibratedWhite: 29/255, alpha: 1),
    .paragraphStyle: para
]).draw(in: NSRect(x: 0, y: H-330, width: W, height: 150))

NSAttributedString(string: "完全本地 · 零网络权限 · 开源免费", attributes: [
    .font: rounded(30, .medium),
    .foregroundColor: NSColor(calibratedWhite: 134/255, alpha: 1),
    .paragraphStyle: para
]).draw(in: NSRect(x: 0, y: H-420, width: W, height: 60))

// 拖拽箭头（上拱弧线，指向 Applications）
let ink = NSColor(calibratedWhite: 29/255, alpha: 0.8)
ink.setStroke()
let arrow = NSBezierPath()
arrow.lineWidth = 13
arrow.lineCapStyle = .round
arrow.move(to: NSPoint(x: 590, y: 295))
arrow.curve(to: NSPoint(x: 850, y: 282),
            controlPoint1: NSPoint(x: 672, y: 392),
            controlPoint2: NSPoint(x: 768, y: 388))
arrow.stroke()
let head = NSBezierPath()
head.lineWidth = 13; head.lineCapStyle = .round
head.move(to: NSPoint(x: 838, y: 352))
head.line(to: NSPoint(x: 850, y: 282))
head.line(to: NSPoint(x: 793, y: 311))
head.stroke()

// 底部脚注（首次打开放行提示；其余安装说明见 Release 正文）
NSAttributedString(string: "首次打开需放行一次：系统设置 → 隐私与安全性 → 仍要打开", attributes: [
    .font: rounded(24, .regular),
    .foregroundColor: NSColor(calibratedWhite: 134/255, alpha: 1),
    .paragraphStyle: para
]).draw(in: NSRect(x: 0, y: 55, width: W, height: 40))

// 写入 PNG 并带 144 DPI（@2x）——否则 Finder 按 72dpi 把背景放大一倍渲染
let cg = rep.cgImage!
let url = URL(fileURLWithPath: out) as CFURL
let dest = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(dest, cg, [
    kCGImagePropertyDPIWidth: 144.0,
    kCGImagePropertyDPIHeight: 144.0,
] as CFDictionary)
guard CGImageDestinationFinalize(dest) else {
    print("PNG 写入失败"); exit(1)
}
print("背景图已生成: \(out)")
