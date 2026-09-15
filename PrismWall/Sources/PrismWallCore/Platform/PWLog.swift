import os

/// 统一日志出口：subsystem 固定为 bundle id,按模块分 category。
/// 红线:任何用户路径只记文件名或用 privacy: .private,不落完整路径到系统日志
enum PWLog {
    static let subsystem = "com.hewentao.prismwall"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let wall = Logger(subsystem: subsystem, category: "wall")
    static let scan = Logger(subsystem: subsystem, category: "scan")
    static let player = Logger(subsystem: subsystem, category: "player")
    static let viewer = Logger(subsystem: subsystem, category: "viewer")
}
