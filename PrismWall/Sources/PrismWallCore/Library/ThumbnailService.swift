import AppKit
import CryptoKit

/// 缩略图服务：内存 NSCache → 磁盘 JPEG → 按需生成（照片 ImageIO / 视频 AVAssetImageGenerator）
/// 防坏缓存三措施：同 key 并发去重（in-flight）+ 原子写盘 + 读盘后有效性校验
final class ThumbnailService: @unchecked Sendable {
    static let shared = ThumbnailService()

    private let cache = NSCache<NSString, NSImage>()
    private let directory: URL
    /// 同 key 的生成任务去重：避免并发请求对同一文件重复生成/写盘竞争
    private var inFlight: [String: Task<NSImage?, Never>] = [:]

    init(directory: URL = LibraryPaths.thumbs) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        cache.countLimit = 2_000
    }

    /// 清除全部缩略图（内存 + 磁盘），下次访问按需重新生成
    func clearCache() {
        cache.removeAllObjects()
        inFlight.removeAll()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    static func cacheKey(fileURL: URL, fsModifiedAt: Date, maxDim: Int) -> String {
        let raw = "\(fileURL.path)|\(Int(fsModifiedAt.timeIntervalSince1970))|\(maxDim)"
        return Insecure.SHA1.hash(data: Data(raw.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// 完成回调在主线程；本方法须在主线程调用
    @MainActor
    func request(
        for item: WallItem, maxDim: Int = 480,
        completion: @escaping @MainActor (NSImage?) -> Void
    ) {
        let key = Self.cacheKey(fileURL: item.fileURL, fsModifiedAt: item.fsModifiedAt, maxDim: maxDim)
        if let image = cache.object(forKey: key as NSString) {
            completion(image)
            return
        }

        // 同 key 并发去重：后到者等待既有的任务（磁盘读+生成都在后台，S-3）
        if let existing = inFlight[key] {
            Task { @MainActor [weak self] in
                let image = await existing.value
                if let image, let self {
                    self.cache.setObject(image, forKey: key as NSString)
                }
                completion(image)
            }
            return
        }

        let url = item.fileURL
        let isVideo = item.isVideo
        let directory = self.directory
        let diskURL = directory.appendingPathComponent("\(key).jpg")
        let task = Task.detached(priority: .utility) { () -> NSImage? in
            // S-3：磁盘命中检查在后台线程做（原先在主线程同步读盘，滚动掉帧源）
            if let image = Self.loadValidImage(at: diskURL) {
                return image
            }
            let cgImage: CGImage?
            if isVideo {
                cgImage = await MetadataReader.videoThumbnailCGImage(
                    url: url, at: 0.1, maxPixelSize: maxDim
                )
            } else {
                cgImage = MetadataReader.thumbnailCGImage(url: url, maxPixelSize: maxDim)
            }
            guard let cgImage else { return nil }
            let rep = NSBitmapImageRep(cgImage: cgImage)
            guard let data = rep.representation(
                using: .jpeg, properties: [.compressionFactor: 0.82]
            ) else { return nil }
            // 原子写盘：先写临时文件再替换，杜绝中断/并发写出的坏缓存
            let tmpURL = directory.appendingPathComponent(UUID().uuidString + ".tmp")
            do {
                try data.write(to: tmpURL, options: .atomic)
                _ = try FileManager.default.replaceItemAt(diskURL, withItemAt: tmpURL)
            } catch {
                try? FileManager.default.removeItem(at: tmpURL)
            }
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }
        inFlight[key] = task

        Task { @MainActor [weak self] in
            let image = await task.value
            self?.inFlight.removeValue(forKey: key)
            if let image {
                self?.cache.setObject(image, forKey: key as NSString)
            }
            completion(image)
        }
    }

    /// 读盘并校验可解码且有有效尺寸（损坏缓存可能解码成功但内容空白）
    private static func loadValidImage(at url: URL) -> NSImage? {
        guard let image = NSImage(contentsOf: url) else { return nil }
        let size = image.representations.first.map { max($0.pixelsWide, $0.pixelsHigh) } ?? 0
        return size > 0 ? image : nil
    }

    /// Nit2：扫描期预生成的缩略图直接落盘（原子写），浏览时磁盘命中、零解码。
    /// 线程安全：只碰磁盘目录与确定参数，可在后台任务调用
    func storeDiskThumbnail(_ cgImage: CGImage, fileURL: URL, fsModifiedAt: Date) {
        let key = Self.cacheKey(fileURL: fileURL, fsModifiedAt: fsModifiedAt, maxDim: 480)
        let diskURL = directory.appendingPathComponent("\(key).jpg")
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let data = rep.representation(
            using: .jpeg, properties: [.compressionFactor: 0.82]
        ) else { return }
        let tmpURL = directory.appendingPathComponent(UUID().uuidString + ".tmp")
        do {
            try data.write(to: tmpURL, options: .atomic)
            _ = try FileManager.default.replaceItemAt(diskURL, withItemAt: tmpURL)
        } catch {
            try? FileManager.default.removeItem(at: tmpURL)
        }
    }
}
