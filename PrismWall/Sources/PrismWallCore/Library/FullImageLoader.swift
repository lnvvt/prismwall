import AppKit
import CoreGraphics

private final class CGImageBox {
    let image: CGImage?
    init(_ image: CGImage?) {
        self.image = image
    }
}

/// 大图加载器：内存缓存 + 按需解码 + 预取（Lightbox 相邻 ±3 张）
final class FullImageLoader: @unchecked Sendable {
    static let shared = FullImageLoader()

    private let cache = NSCache<NSString, CGImageBox>()

    private init() {
        cache.countLimit = 24
        // S-4:按字节钉死上限(约 256MB),setObject 时以像素字节数计 cost;
        // NSCache 内存压力响应之外再加一道硬闸
        cache.totalCostLimit = 256 * 1024 * 1024
    }

    static func cacheKey(_ item: WallItem, maxDim: Int) -> String {
        "\(item.fileURL.path)|\(Int(item.fsModifiedAt.timeIntervalSince1970))|\(maxDim)"
    }

    /// 完成回调在主线程。maxDim 按屏幕长边 2 倍取值，兼顾清晰度与解码成本
    @MainActor
    func request(
        for item: WallItem, maxDim: Int = 2560,
        completion: @escaping @MainActor (CGImage?) -> Void
    ) {
        let key = Self.cacheKey(item, maxDim: maxDim) as NSString
        if let box = cache.object(forKey: key) {
            completion(box.image)
            return
        }
        let url = item.fileURL
        Task.detached(priority: .userInitiated) { [weak self] in
            let image = MetadataReader.thumbnailCGImage(url: url, maxPixelSize: maxDim)
            if let image, let self {
                                let cost = image.width * image.height * 4 // S-4:字节级 cost
                self.cache.setObject(CGImageBox(image), forKey: key, cost: cost)
            }
            let final = image
            await MainActor.run { completion(final) }
        }
    }

    @MainActor
    func prefetch(_ items: [WallItem], maxDim: Int = 2560) {
        for item in items {
            request(for: item, maxDim: maxDim) { _ in }
        }
    }
}
