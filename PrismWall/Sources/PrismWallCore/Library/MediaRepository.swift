import Foundation

/// 媒体库仓库层：所有 SQL 集中在这里
final class MediaRepository: @unchecked Sendable {
    private let database: Database

    init(database: Database) {
        self.database = database
    }

    static func `default`() throws -> MediaRepository {
        let directory = LibraryPaths.root
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try Database(path: LibraryPaths.database.path)
        let repository = MediaRepository(database: database)
        try repository.migrate()
        return repository
    }

    // MARK: - 损坏隔离（S-8）

    /// 启动体检：库文件能打开且 sqlite_master 可查 = 正常（返回 nil）；
    /// 否则把库文件连同 -wal/-shm 隔离为 .corrupt-<时间戳> 留待人工恢复，
    /// 让上层以全新库启动——绝不因库损坏在启动时闪退
    static func quarantineIfCorrupt() -> String? {
        let dbURL = LibraryPaths.database
        guard FileManager.default.fileExists(atPath: dbURL.path) else { return nil }
        do {
            let probe = try Database(path: dbURL.path)
            _ = try probe.query("SELECT count(*) FROM sqlite_master", row: { _ in 0 })
            return nil // 能打开能查询：放行（probe 随作用域释放关闭句柄）
        } catch {
            let stamp = Int(Date().timeIntervalSince1970)
            var moved: [String] = []
            for suffix in ["", "-wal", "-shm"] {
                let src = URL(fileURLWithPath: dbURL.path + suffix)
                guard FileManager.default.fileExists(atPath: src.path) else { continue }
                let dst = URL(fileURLWithPath: "\(dbURL.path)\(suffix).corrupt-\(stamp)")
                try? FileManager.default.moveItem(at: src, to: dst)
                moved.append(dst.lastPathComponent)
            }
            guard !moved.isEmpty else { return nil } // 无文件可动（如纯权限问题），交原路径继续
            return "媒体库文件疑似损坏，已隔离备份为 \(moved.joined(separator: "、"))，本次以全新媒体库启动"
        }
    }

    func migrate() throws {
        try database.execute("""
        CREATE TABLE IF NOT EXISTS sources(
            id INTEGER PRIMARY KEY,
            path TEXT NOT NULL,
            bookmark BLOB,
            state TEXT NOT NULL DEFAULT 'online',
            created_at REAL NOT NULL
        );
        """)
        try database.execute("""
        CREATE TABLE IF NOT EXISTS media(
            id INTEGER PRIMARY KEY,
            source_id INTEGER NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
            rel_path TEXT NOT NULL,
            filename TEXT NOT NULL,
            ext TEXT NOT NULL,
            kind TEXT NOT NULL,
            taken_at REAL,
            fs_modified_at REAL NOT NULL,
            fs_size INTEGER NOT NULL DEFAULT 0,
            duration_ms INTEGER,
            width INTEGER NOT NULL DEFAULT 0,
            height INTEGER NOT NULL DEFAULT 0,
            camera TEXT,
            lens TEXT,
            env_color INTEGER,
            indexed_at REAL NOT NULL DEFAULT 0,
            UNIQUE(source_id, rel_path)
        );
        """)
        try database.execute("CREATE INDEX IF NOT EXISTS idx_media_source_taken ON media(source_id, taken_at);")
        try database.execute("CREATE INDEX IF NOT EXISTS idx_media_kind ON media(kind);")
        try database.execute("""
        CREATE TABLE IF NOT EXISTS view_state(
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        """)
        // 增量迁移：收藏列（旧库不存在时补上）
        try? database.execute("ALTER TABLE media ADD COLUMN is_favorite INTEGER NOT NULL DEFAULT 0;")
        // 增量迁移：视频播放进度（秒），NULL = 未播放过
        try? database.execute("ALTER TABLE media ADD COLUMN playback_seconds REAL;")

        // S-7：版本化迁移 + 迁移前备份。历史迁移在上方以幂等方式执行；
        // user_version 记录结构代数，未来加列必须在 CURRENT_VERSION 下追加新迁移步骤
        let version = currentSchemaVersion()
        if version < Self.currentVersion {
            backupDatabaseFile()
            // 重放到当前版本（ALTER 幂等：列已存在时静默跳过）
            try? database.execute("ALTER TABLE media ADD COLUMN is_favorite INTEGER NOT NULL DEFAULT 0;")
            try? database.execute("ALTER TABLE media ADD COLUMN playback_seconds REAL;")
            try? database.run("PRAGMA user_version = \(Self.currentVersion)")
        }
    }

    /// 当前结构版本（迁移历史：v0 旧库 → v1 +is_favorite → v2 +playback_seconds）
    private static let currentVersion = 2

    private func currentSchemaVersion() -> Int {
        var version = 0
        _ = try? database.query("PRAGMA user_version", row: { statement in
            version = Int(statement.int(0))
            return version
        }).first ?? 0
        return version
    }

    /// 迁移前备份主库文件（先截断 WAL 保证一致性），失败仅记日志不阻断启动
    private func backupDatabaseFile() {
        let source = LibraryPaths.database
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        try? database.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        let target = source.appendingPathExtension("bak")
        do {
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
            try FileManager.default.copyItem(at: source, to: target)
            PWLog.scan.info("迁移前已备份数据库")
        } catch {
            PWLog.scan.error("迁移前备份失败：\(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Sources

    func insertSource(path: String, bookmark: Data?) throws -> Int64 {
        try database.run(
            "INSERT INTO sources(path, bookmark, state, created_at) VALUES(?,?,?,?)",
            [.text(path), bookmark.map { .blob($0) } ?? .null, .text("online"),
             .real(Date().timeIntervalSince1970)]
        )
        return database.lastInsertRowID()
    }

    /// 移除来源及其全部媒体索引（不触碰磁盘文件）
    func deleteSource(id: Int64) throws {
        try database.inTransaction {
            try database.run("DELETE FROM media WHERE source_id=?", [.int(id)])
            try database.run("DELETE FROM sources WHERE id=?", [.int(id)])
        }
    }

    /// 重置媒体库：清空全部来源、媒体索引与视图设置（原始文件不受影响）
    func deleteAllSources() throws {
        try database.inTransaction {
            try database.run("DELETE FROM media")
            try database.run("DELETE FROM sources")
            try database.run("DELETE FROM view_state")
        }
    }

    func listSources() throws -> [SourceRecord] {
        try database.query("SELECT id, path, bookmark, state, created_at FROM sources ORDER BY id") { row in
            SourceRecord(
                id: row.int(0),
                path: row.text(1),
                bookmark: row.blob(2),
                state: row.text(3),
                createdAt: Date(timeIntervalSince1970: row.real(4))
            )
        }
    }

    /// 书签刷新（来源目录在磁盘上移动/书签过期后重签）
    func updateSourceBookmark(sourceId: Int64, bookmark: Data) throws {
        try database.run(
            "UPDATE sources SET bookmark = ? WHERE id = ?",
            [.blob(bookmark), .int(sourceId)]
        )
    }

    func updateSourceState(_ id: Int64, state: String) throws {
        try database.run("UPDATE sources SET state=? WHERE id=?", [.text(state), .int(id)])
    }

    // MARK: - Media

    /// 扫描 diff 用：relPath → (id, mtime, size)
    func mediaIndex(sourceId: Int64) throws -> [String: (id: Int64, mtime: Date, size: Int64)] {
        var index: [String: (Int64, Date, Int64)] = [:]
        let rows = try database.query(
            "SELECT rel_path, id, fs_modified_at, fs_size FROM media WHERE source_id=?",
            [.int(sourceId)]
        ) { row in
            (row.text(0), row.int(1),
             Date(timeIntervalSince1970: row.real(2)), row.int(3))
        }
        for (path, id, mtime, size) in rows {
            index[path] = (id, mtime, size)
        }
        return index
    }

    func upsertBatch(
        adds: [MediaRecord], updates: [MediaRecord], removeIds: [Int64]
    ) throws {
        try database.inTransaction {
            for record in adds {
                try database.run("""
                INSERT INTO media(source_id, rel_path, filename, ext, kind, taken_at,
                                  fs_modified_at, fs_size, duration_ms, width, height,
                                  camera, lens, env_color, indexed_at)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """, Self.bindValues(record))
            }
            for record in updates {
                try database.run("""
                UPDATE media SET kind=?, taken_at=?, fs_modified_at=?, fs_size=?, duration_ms=?,
                                 width=?, height=?, camera=?, lens=?, env_color=?, indexed_at=?
                WHERE id=?
                """, [
                    .text(record.kind.rawValue),
                    record.takenAt.map { .real($0.timeIntervalSince1970) } ?? .null,
                    .real(record.fsModifiedAt.timeIntervalSince1970),
                    .int(record.fsSize),
                    record.durationMs.map { .int($0) } ?? .null,
                    .int(Int64(record.width)),
                    .int(Int64(record.height)),
                    record.camera.map { .text($0) } ?? .null,
                    record.lens.map { .text($0) } ?? .null,
                    record.envColor.map { .int($0) } ?? .null,
                    .real(Date().timeIntervalSince1970),
                    .int(record.id),
                ])
            }
            for id in removeIds {
                try database.run("DELETE FROM media WHERE id=?", [.int(id)])
            }
        }
    }

    /// 墙数据：排序键 = 拍摄时间（缺失回退文件修改时间），新→旧；可按收藏/来源/类型过滤
    func allMedia(
        favoritesOnly: Bool = false, sourceId: Int64? = nil, kind: MediaTypeFilter = .all
    ) throws -> [MediaRecord] {
        var whereParts: [String] = []
        var binds: [SQLiteValue] = []
        if favoritesOnly {
            whereParts.append("is_favorite = 1")
        }
        if let sourceId {
            whereParts.append("source_id = ?")
            binds.append(.int(sourceId))
        }
        switch kind {
        case .all: break
        case .photo: whereParts.append("kind = 'photo'")
        case .video: whereParts.append("kind = 'video'")
        }
        let whereClause = whereParts.isEmpty ? "" : "WHERE " + whereParts.joined(separator: " AND ")
        return try database.query("""
        SELECT id, source_id, rel_path, filename, ext, kind, taken_at, fs_modified_at,
               fs_size, duration_ms, width, height, camera, lens, env_color, is_favorite
        FROM media \(whereClause)
        ORDER BY CASE WHEN taken_at IS NULL OR taken_at = 0
                      THEN fs_modified_at ELSE taken_at END DESC, filename ASC
        """, binds) { row in
            MediaRecord(
                id: row.int(0),
                sourceId: row.int(1),
                relPath: row.text(2),
                filename: row.text(3),
                ext: row.text(4),
                kind: MediaKind(rawValue: row.text(5)) ?? .unsupported,
                takenAt: row.isNull(6) ? nil : Date(timeIntervalSince1970: row.real(6)),
                fsModifiedAt: Date(timeIntervalSince1970: row.real(7)),
                fsSize: row.int(8),
                durationMs: row.isNull(9) ? nil : row.int(9),
                width: Int(row.int(10)),
                height: Int(row.int(11)),
                camera: row.isNull(12) ? nil : row.text(12),
                lens: row.isNull(13) ? nil : row.text(13),
                envColor: row.isNull(14) ? nil : row.int(14),
                isFavorite: row.int(15) == 1
            )
        }
    }

    func setFavorite(ids: [Int64], isFavorite: Bool) throws {
        guard !ids.isEmpty else { return }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        try database.run(
            "UPDATE media SET is_favorite=? WHERE id IN (\(placeholders))",
            [.int(isFavorite ? 1 : 0)] + ids.map { .int($0) }
        )
    }

    func favoriteCount() throws -> Int {
        try database.query(
            "SELECT COUNT(*) FROM media WHERE is_favorite = 1", row: { Int($0.int(0)) }
        ).first ?? 0
    }

    /// 读取视频续播位置（从未播放过返回 nil；播完的返回 nil 重新开始）
    func playbackSeconds(mediaId: Int64) -> Double? {
        try? database.query(
            "SELECT playback_seconds FROM media WHERE id=?", [.int(mediaId)]
        ) { $0.real(0) }.first.flatMap { value in
            (value > 0.5 && value.isFinite) ? value : nil
        }
    }

    func setPlaybackSeconds(mediaId: Int64, seconds: Double) {
        try? database.run(
            "UPDATE media SET playback_seconds=? WHERE id=?",
            [.real(seconds), .int(mediaId)]
        )
    }

    func mediaCount() throws -> Int {
        try database.query("SELECT COUNT(*) FROM media", row: { Int($0.int(0)) }).first ?? 0
    }

    // MARK: - 视图状态（密度、滚动位置等，随库持久化）

    func viewState(forKey key: String) -> String? {
        try? database.query(
            "SELECT value FROM view_state WHERE key=?", [.text(key)]
        ) { $0.text(0) }.first
    }

    func setViewState(_ value: String, forKey key: String) {
        try? database.run(
            "INSERT INTO view_state(key, value) VALUES(?,?) " +
            "ON CONFLICT(key) DO UPDATE SET value=excluded.value",
            [.text(key), .text(value)]
        )
    }

    func countsBySource() throws -> [Int64: Int] {
        var result: [Int64: Int] = [:]
        let rows = try database.query(
            "SELECT source_id, COUNT(*) FROM media GROUP BY source_id"
        ) { row in (row.int(0), Int(row.int(1))) }
        for (sourceId, count) in rows {
            result[sourceId] = count
        }
        return result
    }

    private static func bindValues(_ record: MediaRecord) -> [SQLiteValue] {
        [
            .int(record.sourceId),
            .text(record.relPath),
            .text(record.filename),
            .text(record.ext),
            .text(record.kind.rawValue),
            record.takenAt.map { .real($0.timeIntervalSince1970) } ?? .null,
            .real(record.fsModifiedAt.timeIntervalSince1970),
            .int(record.fsSize),
            record.durationMs.map { .int($0) } ?? .null,
            .int(Int64(record.width)),
            .int(Int64(record.height)),
            record.camera.map { .text($0) } ?? .null,
            record.lens.map { .text($0) } ?? .null,
            record.envColor.map { .int($0) } ?? .null,
            .real(Date().timeIntervalSince1970),
        ]
    }
}

enum LibraryPaths {
    static var root: URL {
        #if DEBUG
        // 营销截图专用：PW_DEMO_DATA_DIR 指向独立数据目录，与真实媒体库完全隔离
        if let demo = ProcessInfo.processInfo.environment["PW_DEMO_DATA_DIR"] {
            return URL(fileURLWithPath: demo, isDirectory: true)
        }
        #endif
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("PrismWall", isDirectory: true)
    }

    static var database: URL {
        root.appendingPathComponent("prismwall.sqlite")
    }

    static var thumbs: URL {
        root.appendingPathComponent("thumbs", isDirectory: true)
    }
}
