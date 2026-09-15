#if DEBUG
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// 金丝雀数据集生成器：批量产出带差异内容的小 JPEG（800×533）
/// 用途：PRD F1/F2 性能基准（首扫速度、10 万条滚动帧率）
/// 调用：PrismWall --canary 10000 ~/.prismwall-canary
public enum CanaryGenerator {
    public static func main(count: Int, directory: String) {
        let expanded = (directory as NSString).expandingTildeInPath
        let root = URL(fileURLWithPath: expanded, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            NSLog("[canary] 无法创建目录 %@: %@", root.path, error.localizedDescription)
            exit(1)
        }
        let started = Date()
        NSLog("[canary] 开始生成 %d 张 JPEG → %@", count, root.path)

        var written = 0
        var skipped = 0
        for index in 0..<count {
            // 分片子目录模拟真实文件夹结构
            let shard = index / 500 + 1
            let dir = root.appendingPathComponent(
                String(format: "shard-%03d", shard), isDirectory: true
            )
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(String(format: "canary-%06d.jpg", index))
            // 断点续跑：已存在的跳过（命令环境可能回收长后台任务，分多次跑完）
            if FileManager.default.fileExists(atPath: url.path) {
                skipped += 1
                continue
            }
            if writeJPEG(url: url, index: index) {
                written += 1
            }
            if (written + skipped) % 500 == 0 {
                NSLog("[canary] 新写 %d 跳过 %d / %d (%.0f%%)",
                      written, skipped, count,
                      Double(written + skipped) / Double(count) * 100)
            }
        }
        let elapsed = Date().timeIntervalSince(started)
        NSLog("[canary] 完成：新写 %d 跳过 %d，耗时 %.1fs → %@",
              written, skipped, elapsed, root.path)
        exit(0)
    }

    /// 画一张有辨识度的图：色相随编号变化 + 斜条纹 + 编号水印
    /// 紧凑尺寸（400×267 q0.55 ≈ 8KB/张）：10 万张约 800MB，避免触发写入配额
    private static func writeJPEG(url: URL, index: Int) -> Bool {
        let width = 400
        let height = 267
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }

        let hue = CGFloat(index % 97) / 97
        context.setFillColor(NSColor(hue: hue, saturation: 0.45, brightness: 0.75, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // 斜条纹：内容有差异，避免所有缩略图长得一样
        context.setFillColor(NSColor.white.withAlphaComponent(0.18).cgColor)
        let stripeHeight = CGFloat(height)
        for stripe in 0..<10 {
            let offset = CGFloat((index * 37 + stripe * 90) % width)
            context.move(to: CGPoint(x: offset, y: 0))
            context.addLine(to: CGPoint(x: offset + 60, y: 0))
            context.addLine(to: CGPoint(x: offset + 60 - stripeHeight / 2, y: stripeHeight))
            context.addLine(to: CGPoint(x: offset - stripeHeight / 2, y: stripeHeight))
            context.closePath()
            context.fillPath()
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let label = String(format: "canary-%06d", index)
        NSAttributedString(string: label, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 48, weight: .bold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.85),
        ]).draw(at: NSPoint(x: 30, y: 60))
        NSGraphicsContext.restoreGraphicsState()

        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(
                  url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
              )
        else { return false }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: 0.55,
        ] as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }
}

#endif
