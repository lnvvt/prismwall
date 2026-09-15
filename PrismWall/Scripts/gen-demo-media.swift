#!/usr/bin/env swift
// 营销截图示例媒体生成器：纯合成内容（渐变+柔光斑），不含任何真实照片/视频。
// 产出：/tmp/pw-demo/示例图库/{山野,城市,海岸}/ 照片×120 + 视频×5
// 拍摄日期伪造为跨月分布（EXIF + 文件日期），让「按时间」「按文件夹」分组视图都有真实观感。
// 用法：swift Scripts/gen-demo-media.swift
import AppKit
import AVFoundation
import CoreVideo
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: "/tmp/pw-demo/示例图库", isDirectory: true)

struct Theme {
    let folder: String
    let photoPrefix: String
    let bg: [(CGFloat, CGFloat, CGFloat)]      // (hue, saturation, brightness)
    let accent: [(CGFloat, CGFloat, CGFloat)]
}

let themes: [Theme] = [
    Theme(folder: "山野", photoPrefix: "IMG_70",
          bg:      [(0.34, 0.45, 0.34), (0.40, 0.48, 0.30), (0.30, 0.32, 0.44), (0.38, 0.40, 0.38)],
          accent:  [(0.12, 0.55, 0.60), (0.55, 0.45, 0.62), (0.45, 0.38, 0.55)]),
    Theme(folder: "城市", photoPrefix: "DSC_21",
          bg:      [(0.62, 0.28, 0.26), (0.60, 0.30, 0.20), (0.72, 0.22, 0.34), (0.58, 0.18, 0.30)],
          accent:  [(0.08, 0.75, 0.62), (0.85, 0.60, 0.55), (0.55, 0.70, 0.62)]),
    Theme(folder: "海岸", photoPrefix: "P101",
          bg:      [(0.55, 0.55, 0.46), (0.52, 0.58, 0.50), (0.50, 0.42, 0.58), (0.56, 0.48, 0.62)],
          accent:  [(0.10, 0.60, 0.75), (0.97, 0.55, 0.62), (0.58, 0.50, 0.72)]),
]

func color(_ c: (CGFloat, CGFloat, CGFloat), _ alpha: CGFloat = 1) -> CGColor {
    NSColor(hue: c.0, saturation: c.1, brightness: c.2, alpha: alpha).cgColor
}

func paint(_ ctx: CGContext, width w: CGFloat, height h: CGFloat,
           theme: Theme, seed: Int, t: Double) {
    srand48(seed * 7919 + 13)
    let rect = CGRect(x: 0, y: 0, width: w, height: h)

    // 背景对角渐变
    let c0 = color(theme.bg[seed % theme.bg.count])
    let c1 = color(theme.bg[(seed + 2) % theme.bg.count])
    let angle = CGFloat(.pi / 3 + drand48() * 0.7)
    let dx = CGFloat(cos(angle)) * w, dy = CGFloat(sin(angle)) * h
    if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                             colors: [c0, c1] as CFArray, locations: [0, 1]) {
        ctx.saveGState()
        ctx.drawLinearGradient(grad,
                               start: CGPoint(x: w / 2 - dx, y: h / 2 + dy),
                               end: CGPoint(x: w / 2 + dx, y: h / 2 - dy),
                               options: [])
        ctx.restoreGState()
    }

    // 柔光圆斑（视频帧上缓慢漂移）
    let blobs = 3 + seed % 2
    for b in 0..<blobs {
        let col = color(theme.accent[(seed + b) % theme.accent.count], 0.5)
        var cx = CGFloat(drand48()) * w
        var cy = CGFloat(drand48()) * h
        let r = h * CGFloat(0.35 + drand48() * 0.45)
        let phase = drand48() * .pi * 2
        cx += CGFloat(sin(t * 0.35 + phase)) * w * 0.06
        cy += CGFloat(cos(t * 0.28 + phase)) * h * 0.06
        if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: [col, CGColor(gray: 0, alpha: 0)] as CFArray,
                                 locations: [0, 1]) {
            ctx.saveGState()
            ctx.clip(to: rect)
            ctx.drawRadialGradient(grad,
                                   startCenter: CGPoint(x: cx, y: cy), startRadius: 0,
                                   endCenter: CGPoint(x: cx, y: cy), endRadius: r,
                                   options: [])
            ctx.restoreGState()
        }
    }

    // 每三张加两道斜向亮带，增加构图差异
    if seed % 3 == 0 {
        let col = color(theme.accent[(seed + 2) % theme.accent.count], 0.10)
        ctx.saveGState()
        ctx.translateBy(x: w * CGFloat(drand48() * 0.4), y: 0)
        ctx.rotate(by: CGFloat(-0.5 - drand48() * 0.3))
        ctx.setFillColor(col)
        ctx.fill(CGRect(x: -w, y: -h, width: w * CGFloat(0.06 + drand48() * 0.08), height: h * 3))
        ctx.fill(CGRect(x: w * CGFloat(0.5 + drand48() * 0.4), y: -h,
                        width: w * CGFloat(0.04 + drand48() * 0.06), height: h * 3))
        ctx.restoreGState()
    }
}

let cal = Calendar(identifier: .gregorian)
func dateOn(_ y: Int, _ m: Int, _ d: Int, _ hh: Int = 10, _ mm: Int = 24) -> Date {
    cal.date(from: DateComponents(year: y, month: m, day: d, hour: hh, minute: mm))!
}

func stampFileDates(_ url: URL, _ date: Date) {
    try? FileManager.default.setAttributes(
        [.modificationDate: date, .creationDate: date], ofItemAtPath: url.path)
}

// ---------- 照片 ----------
let photoW = 800, photoH = 533
var counters = [Int](repeating: 0, count: themes.count)
var photoDates: [Date] = []
for i in 0..<120 {
    // 近两个月占 7 成（首屏墙饱满），其余铺在 1-7 月（按时间分组有月份头）
    if i < 70 {
        photoDates.append(dateOn(2026, 8, 15 + i % 31, 6 + i % 3 * 4, (i * 17) % 60))
    } else {
        photoDates.append(dateOn(2026, 1 + (i - 70) % 7, 3 + (i * 11) % 26, 7 + i % 3 * 5, (i * 23) % 60))
    }
}
var written = 0
for i in 0..<120 {
    let theme = themes[i % themes.count]
    counters[i % themes.count] += 1
    let dir = root.appendingPathComponent(theme.folder, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("\(theme.photoPrefix)\(100 + counters[i % themes.count]).jpg")

    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: photoW, height: photoH, bitsPerComponent: 8,
                        bytesPerRow: photoW * 4, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    paint(ctx, width: CGFloat(photoW), height: CGFloat(photoH), theme: theme, seed: i + 1, t: 0)
    let img = ctx.makeImage()!

    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
        fatalError("dest create failed: \(url.path)")
    }
    let df = DateFormatter()
    df.dateFormat = "yyyy:MM:dd HH:mm:ss"
    let dateStr = df.string(from: photoDates[i])
    let props: [CFString: Any] = [
        kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: dateStr],
        kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFDateTime: dateStr],
    ]
    CGImageDestinationAddImage(dest, img, props as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { fatalError("finalize failed") }
    stampFileDates(url, photoDates[i])
    written += 1
    if written % 40 == 0 { print("[demo] photos \(written)/120") }
}

// ---------- 视频 ----------
func newPixelBuffer(_ w: Int, _ h: Int) throws -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    let status = CVPixelBufferCreate(kCFAllocatorDefault, w, h,
                                     kCVPixelFormatType_32BGRA, nil, &pb)
    guard status == kCVReturnSuccess, let buffer = pb else {
        throw NSError(domain: "demo", code: Int(status))
    }
    return buffer
}

let videoSpecs: [(Int, Date, String)] = [
    (0, dateOn(2026, 9, 10, 15, 42), "VID_3001.mp4"),
    (1, dateOn(2026, 9, 12, 19, 8),  "VID_3002.mp4"),
    (2, dateOn(2026, 9, 8, 11, 31),  "VID_3003.mp4"),
    (0, dateOn(2026, 9, 5, 17, 56),  "VID_3004.mp4"),
    (1, dateOn(2026, 9, 13, 9, 14),  "VID_3005.mp4"),
    (2, dateOn(2026, 9, 3, 20, 47),  "VID_3006.mp4"),
    (0, dateOn(2026, 9, 1, 8, 22),   "VID_3007.mp4"),
    (1, dateOn(2026, 9, 9, 14, 3),   "VID_3008.mp4"),
    (2, dateOn(2026, 9, 6, 16, 39),  "VID_3009.mp4"),
]

for (v, spec) in videoSpecs.enumerated() {
    let (themeIndex, date, name) = spec
    let theme = themes[themeIndex]
    let dir = root.appendingPathComponent(theme.folder, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent(name)
    try? FileManager.default.removeItem(at: url)  // AVAssetWriter 不能覆盖已有文件

    let w = 1280, h = 720, fps = 30, frames = 120  // 4 秒
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: w,
        AVVideoHeightKey: h,
        AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 2_500_000],
    ])
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w,
            kCVPixelBufferHeightKey as String: h,
        ])
    writer.add(input)
    guard writer.startWriting() else { fatalError("startWriting: \(String(describing: writer.error))") }
    writer.startSession(atSourceTime: .zero)

    for frame in 0..<frames {
        let pb = try newPixelBuffer(w, h)
        CVPixelBufferLockBaseAddress(pb, [])
        if let base = CVPixelBufferGetBaseAddress(pb),
           let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8,
                               bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                   | CGBitmapInfo.byteOrder32Little.rawValue) {
            paint(ctx, width: CGFloat(w), height: CGFloat(h), theme: theme,
                  seed: 50 + v, t: Double(frame) / Double(fps))
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.004) }
        let time = CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps))
        guard adaptor.append(pb, withPresentationTime: time) else {
            fatalError("append: \(String(describing: writer.error))")
        }
    }
    input.markAsFinished()
    let sem = DispatchSemaphore(value: 0)
    writer.finishWriting { sem.signal() }
    sem.wait()
    guard writer.status == .completed else { fatalError("writer: \(String(describing: writer.error))") }
    stampFileDates(url, date)
    print("[demo] video \(v + 1)/\(videoSpecs.count) → \(url.lastPathComponent)")
}

print("[demo] 完成：照片 120 + 视频 \(videoSpecs.count) → \(root.path)")
exit(0)
