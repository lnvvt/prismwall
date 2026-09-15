import AppKit
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// 文件元数据提取：照片走 ImageIO（同步、毫秒级），视频走 AVFoundation（异步）
enum MetadataReader {
    struct PhotoInfo {
        var width = 0
        var height = 0
        var takenAt: Date?
        var camera: String?
        var lens: String?
    }

    struct VideoInfo {
        var width = 0
        var height = 0
        var durationMs: Int64 = 0
        var takenAt: Date?
    }

    private static let exifDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    static func isPhotoExtension(_ ext: String) -> Bool {
        ["jpg", "jpeg", "png", "heic", "webp", "gif", "tif", "tiff", "bmp"].contains(ext)
    }

    static func isVideoExtension(_ ext: String) -> Bool {
        ["mp4", "mov", "m4v", "avi", "mkv"].contains(ext)
    }

    static func kind(forExtension ext: String) -> MediaKind {
        if isPhotoExtension(ext) { return .photo }
        if isVideoExtension(ext) { return .video }
        return .unsupported
    }

    static func photoInfo(at url: URL) -> PhotoInfo {
        var info = PhotoInfo()
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return info }

        info.width = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        info.height = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        let exif = props[kCGImagePropertyExifDictionary] as? [String: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [String: Any]

        if let dateString = exif?[kCGImagePropertyExifDateTimeOriginal as String] as? String {
            info.takenAt = exifDateFormatter.date(from: dateString)
        }
        if let make = tiff?["Make"] as? String, let model = tiff?["Model"] as? String {
            info.camera = "\(make) \(model)"
        }
        info.lens = exif?["LensModel"] as? String
        return info
    }

    static func videoInfo(at url: URL) async -> VideoInfo {
        var info = VideoInfo()
        let asset = AVURLAsset(url: url)
        let duration = (try? await asset.load(.duration)) ?? .zero
        info.durationMs = Int64(duration.seconds * 1000)
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let size = try? await track.load(.naturalSize) {
            info.width = Int(abs(size.width))
            info.height = Int(abs(size.height))
        }
        if let metadata = try? await asset.load(.metadata) {
            let items = AVMetadataItem.metadataItems(
                from: metadata, filteredByIdentifier: .commonIdentifierCreationDate
            )
            if let creation = items.first {
                info.takenAt = try? await creation.load(.dateValue)
                if info.takenAt == nil, let string = try? await creation.load(.stringValue) {
                    info.takenAt = exifDateFormatter.date(from: string)
                }
            }
        }
        return info
    }

    /// 32×32 降采样取平均色作为环境主色
    static func dominantColor(at url: URL, kind: MediaKind) async -> Int64? {
        let cgImage: CGImage?
        switch kind {
        case .photo:
            cgImage = thumbnailCGImage(url: url, maxPixelSize: 32)
        case .video:
            cgImage = await videoThumbnailCGImage(url: url, at: 0.1, maxPixelSize: 32)
        case .unsupported:
            return nil
        }
        guard let cgImage else { return nil }
        return encodeColor(cgImage)
    }

    /// Nit2：视频一次解码（480px）同时产出缩略图与环境主色。
    /// 扫描期调用并把 frame 落盘到缩略图缓存，浏览时磁盘命中、零解码
    static func videoFrameWithColor(url: URL) async -> (frame: CGImage?, color: Int64?) {
        guard let cgImage = await videoThumbnailCGImage(url: url, at: 0.1, maxPixelSize: 480) else {
            return (nil, nil)
        }
        return (cgImage, encodeColor(cgImage))
    }

    private static func encodeColor(_ cgImage: CGImage) -> Int64? {
        guard let color = Self.averageColor(cgImage) else { return nil }
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return EnvColor.encode(hue: Double(hue), saturation: Double(saturation), brightness: Double(brightness))
    }

    static func thumbnailCGImage(url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    static func videoThumbnailCGImage(url: URL, at fraction: Double, maxPixelSize: Int) async -> CGImage? {
        let asset = AVURLAsset(url: url)
        let duration = (try? await asset.load(.duration)) ?? .zero
        guard duration.seconds > 0 else { return nil }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
        let time = CMTime(seconds: duration.seconds * fraction, preferredTimescale: 600)
        return try? await generator.image(at: time).image
    }

    private static func averageColor(_ image: CGImage) -> NSColor? {
        let width = 1, height = 1
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &pixel, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return NSColor(
            red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255,
            blue: CGFloat(pixel[2]) / 255, alpha: 1
        )
    }
}
