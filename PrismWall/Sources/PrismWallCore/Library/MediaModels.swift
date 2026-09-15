import Foundation

public enum MediaKind: String, Sendable {
    case photo
    case video
    case unsupported
}

public struct SourceRecord: Identifiable, Sendable {
    public let id: Int64
    public let path: String
    public let bookmark: Data?
    /// var：运行期可标记离线（书签失效/目录不可读），侧栏随之警示
    public var state: String // online | offline | scanning
    public let createdAt: Date

    public init(
        id: Int64, path: String, bookmark: Data?, state: String, createdAt: Date
    ) {
        self.id = id
        self.path = path
        self.bookmark = bookmark
        self.state = state
        self.createdAt = createdAt
    }
}

public struct MediaRecord: Sendable {
    public var id: Int64
    public let sourceId: Int64
    public let relPath: String
    public let filename: String
    public let ext: String
    public let kind: MediaKind
    public let takenAt: Date?
    public let fsModifiedAt: Date
    public let fsSize: Int64
    public let durationMs: Int64?
    public let width: Int
    public let height: Int
    public let camera: String?
    public let lens: String?
    public let envColor: Int64?
    public var isFavorite: Bool = false

    /// 分组用的文件夹路径（relPath 去掉文件名；根目录显示来源名）
    public var folderPath: String {
        let path = (relPath as NSString).deletingLastPathComponent
        return path.isEmpty ? "（根目录）" : path
    }

    public init(
        id: Int64 = 0, sourceId: Int64, relPath: String, filename: String, ext: String,
        kind: MediaKind, takenAt: Date?, fsModifiedAt: Date, fsSize: Int64,
        durationMs: Int64?, width: Int, height: Int, camera: String?, lens: String?,
        envColor: Int64?, isFavorite: Bool = false
    ) {
        self.id = id
        self.sourceId = sourceId
        self.relPath = relPath
        self.filename = filename
        self.ext = ext
        self.kind = kind
        self.takenAt = takenAt
        self.fsModifiedAt = fsModifiedAt
        self.fsSize = fsSize
        self.durationMs = durationMs
        self.width = width
        self.height = height
        self.camera = camera
        self.lens = lens
        self.envColor = envColor
    }
}

/// 缩略墙展示项（MediaRecord 的投影）
public struct WallItem: Identifiable, Sendable {
    public let id: Int64
    public let date: Date
    public let isVideo: Bool
    public let envColor: Int64?
    public let fileURL: URL
    public let filename: String
    public let fsModifiedAt: Date
    public let takenAt: Date?
    public let width: Int
    public let height: Int
    public let camera: String?
    public let lens: String?
    public let durationMs: Int64?
    public var isFavorite: Bool = false
    /// 所属来源内子文件夹路径（按文件夹分组用；根目录为 "（根目录）"）
    public let folderPath: String
    /// 所属来源显示名（图库按文件夹分组时做一级归类）
    public let sourceName: String

    public init(
        id: Int64, date: Date, isVideo: Bool, envColor: Int64?, fileURL: URL,
        filename: String, fsModifiedAt: Date, takenAt: Date?, width: Int, height: Int,
        camera: String?, lens: String?, durationMs: Int64?, isFavorite: Bool = false,
        folderPath: String = "", sourceName: String = ""
    ) {
        self.id = id
        self.date = date
        self.isVideo = isVideo
        self.envColor = envColor
        self.fileURL = fileURL
        self.filename = filename
        self.fsModifiedAt = fsModifiedAt
        self.takenAt = takenAt
        self.width = width
        self.height = height
        self.camera = camera
        self.lens = lens
        self.durationMs = durationMs
        self.isFavorite = isFavorite
        self.folderPath = folderPath
        self.sourceName = sourceName
    }
}

/// 按月分区的墙数据（新月份在前）
public struct WallSection: Identifiable, Sendable {
    public let id: Int // year*12+month
    public let title: String
    public var items: [WallItem]

    public init(id: Int, title: String, items: [WallItem]) {
        self.id = id
        self.title = title
        self.items = items
    }
}

/// 类型过滤：全部 / 只看照片 / 只看视频
public enum MediaTypeFilter: String, Sendable, CaseIterable {
    case all
    case photo
    case video

    public var title: String {
        switch self {
        case .all: "全部"
        case .photo: "照片"
        case .video: "视频"
        }
    }

    public var symbolName: String {
        switch self {
        case .all: "photo.on.rectangle.angled"
        case .photo: "photo"
        case .video: "video"
        }
    }
}

/// 分组方式：按时间（月）/ 按文件夹路径 / 不分组平铺
public enum LibraryGrouping: String, Sendable, CaseIterable {
    case byTime
    case byFolder
    case flat

    public var title: String {
        switch self {
        case .byTime: "按时间"
        case .byFolder: "按文件夹"
        case .flat: "不分组"
        }
    }

    public var symbolName: String {
        switch self {
        case .byTime: "calendar"
        case .byFolder: "folder"
        case .flat: "square.grid.3x3"
        }
    }
}

/// 环境主色编码：hue(0-359) * 10000 + sat(0-99) * 100 + bright(0-99)
public enum EnvColor {
    public static func encode(hue: Double, saturation: Double, brightness: Double) -> Int64 {
        let h = Int64(max(0, min(359, Int(hue * 360))))
        let s = Int64(max(0, min(99, Int(saturation * 100))))
        let b = Int64(max(0, min(99, Int(brightness * 100))))
        return h * 10_000 + s * 100 + b
    }

    public static func decode(_ value: Int64?) -> (hue: Double, saturation: Double, brightness: Double)? {
        guard let value, value >= 0 else { return nil }
        let hue = Double(value / 10_000) / 360
        let saturation = Double((value / 100) % 100) / 100
        let brightness = Double(value % 100) / 100
        return (hue, saturation, brightness)
    }
}
