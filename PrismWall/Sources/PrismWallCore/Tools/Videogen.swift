#if DEBUG
import AVFoundation
import AppKit
import CoreVideo

/// S2 测试素材生成器：生成带时间码大字的 H.264 视频，同步偏差肉眼与数值均可验证
public enum Videogen {
    struct GenError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// CLI 入口：完成后进程退出
    public static func main(count: Int, directory: String) {
        do {
            try run(count: count, directory: directory)
            NSLog("[videogen] all done")
            exit(0)
        } catch {
            NSLog("[videogen] FAILED: \(error)")
            exit(1)
        }
    }

    public static func run(count: Int, directory: String) throws {
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )
        for i in 1...max(1, count) {
            let url = URL(fileURLWithPath: directory)
                .appendingPathComponent(String(format: "sample_%02d.mp4", i))
            NSLog("[videogen] generating %@", url.lastPathComponent)
            try makeVideo(index: i, url: url)
            NSLog("[videogen] done %@", url.lastPathComponent)
        }
    }

    static func makeVideo(index: Int, url: URL) throws {
        let width = 1920
        let height = 1080
        let fps = 30
        let totalFrames = fps * 12 // 12s

        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 6_000_000],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )
        writer.add(input)
        guard writer.startWriting() else {
            throw GenError(message: "startWriting: \(String(describing: writer.error))")
        }
        writer.startSession(atSourceTime: .zero)

        let hue = Double(index) * 0.13
        for frame in 0..<totalFrames {
            let pixelBuffer = try newPixelBuffer(width: width, height: height)
            drawFrame(index: index, frame: frame, fps: fps, hue: hue, into: pixelBuffer)
            while !input.isReadyForMoreMediaData {
                Thread.sleep(forTimeInterval: 0.005)
            }
            let time = CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps))
            guard adaptor.append(pixelBuffer, withPresentationTime: time) else {
                throw GenError(message: "append: \(String(describing: writer.error))")
            }
        }
        input.markAsFinished()

        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }
        semaphore.wait()
        guard writer.status == .completed else {
            throw GenError(message: "finish: \(String(describing: writer.error))")
        }
    }

    static func newPixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attrs = [kCVPixelBufferCGImageCompatibilityKey as String: true] as CFDictionary
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs, &buffer
        )
        guard status == kCVReturnSuccess, let buffer else {
            throw GenError(message: "CVPixelBufferCreate status=\(status)")
        }
        return buffer
    }

    static func drawFrame(
        index: Int, frame: Int, fps: Int, hue: Double, into pixelBuffer: CVPixelBuffer
    ) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard let ctx = CGContext(
            data: base,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return }

        let w = CGFloat(width)
        let h = CGFloat(height)
        let seconds = frame / fps

        // 背景色随色相区分视频编号、随时间缓变亮度
        let bg = NSColor(
            hue: hue.truncatingRemainder(dividingBy: 1),
            saturation: 0.45,
            brightness: 0.5 + 0.1 * sin(Double(seconds)),
            alpha: 1
        )
        ctx.setFillColor(bg.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

        // 移动白条：同步偏差肉眼可见
        let barX = CGFloat(frame % (Int(w) + 120)) - 60
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.85).cgColor)
        ctx.fill(CGRect(x: barX, y: 0, width: 24, height: h))

        // 时间码大字
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let timecode = String(
            format: "V%d  %02d:%02d.%02d",
            index, seconds / 60, seconds % 60, frame % fps
        )
        NSAttributedString(string: timecode, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 110, weight: .bold),
            .foregroundColor: NSColor.white,
        ]).draw(at: NSPoint(x: 90, y: h * 0.60))

        let subtitle = String(
            format: "PrismWall S2 同步测试素材 · V%d · 30fps 1080p · 第 %d 秒", index, seconds
        )
        NSAttributedString(string: subtitle, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 34, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.8),
        ]).draw(at: NSPoint(x: 94, y: h * 0.42))
        NSGraphicsContext.restoreGraphicsState()
    }
}

#endif
