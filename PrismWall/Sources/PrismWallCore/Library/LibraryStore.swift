import AppKit
import Observation
import SwiftUI

/// 媒体库编排层：来源管理、扫描调度、墙数据（sections）供给、监听接入
@MainActor
@Observable
public final class LibraryStore {
    public enum AppearanceMode: String, Sendable {
        case system
        case light
        case dark

        public var colorScheme: ColorScheme? {
            switch self {
            case .system: nil
            case .light: .light
            case .dark: .dark
            }
        }

        public var nsAppearance: NSAppearance? {
            switch self {
            case .system: nil // 跟随系统
            case .light: NSAppearance(named: .aqua)
            case .dark: NSAppearance(named: .darkAqua)
            }
        }
    }

    public private(set) var sources: [SourceRecord] = []
    public private(set) var sections: [WallSection] = []
    /// 全部条目按墙内显示顺序平铺（Lightbox 导航顺序 = 当前排序）
    public private(set) var flatItems: [WallItem] = []
    public private(set) var totalCount = 0
    /// 全库媒体数（不受侧栏过滤影响，图库行显示用）
    public private(set) var galleryCount = 0
    public private(set) var sourceCounts: [Int64: Int] = [:]
    public private(set) var isScanning = false
    public private(set) var progressText = ""
    /// 索引真实进度 0...1（done/total）：主界面进度条用；
    /// 完成时置 1（进度条停在满格），空闲时为 0
    public private(set) var scanProgress: Double = 0

    /// B-1/S-2：进行中的扫描任务（按来源，可取消）与已启动的安全作用域访问
    private var activeScanTasks: [Int64: Task<Void, Never>] = [:]
    private var scopedAccessURLs: [Int64: URL] = [:]
    /// S-8：启动检测到库损坏并已隔离重建时的用户提示（非 nil 时 App 弹一次性通知）
    public private(set) var databaseQuarantined: String?

    public func clearDatabaseNotice() { databaseQuarantined = nil }
    public private(set) var appearanceMode: AppearanceMode = .system
    public private(set) var favoriteCount = 0

    /// 侧栏单选：图库（全部）/ 收藏 / 单个来源
    public enum LibraryFilter: Hashable, Sendable {
        case all
        case favorites
        case source(Int64)

        var persisted: String {
            switch self {
            case .all: "all"
            case .favorites: "favorites"
            case .source(let id): "source-\(id)"
            }
        }

        static func from(persisted: String) -> LibraryFilter? {
            if persisted == "all" { return .all }
            if persisted == "favorites" { return .favorites }
            if persisted.hasPrefix("source-"), let id = Int64(persisted.dropFirst(7)) {
                return .source(id)
            }
            return nil
        }
    }

    public private(set) var filter: LibraryFilter = .all
    /// 类型过滤（全部/照片/视频），持久化
    public private(set) var typeFilter: MediaTypeFilter = .all
    /// 分组方式（按时间/按文件夹/平铺）；nil = 跟随范围默认（图库按时间/来源按文件夹）
    public private(set) var groupingOverride: LibraryGrouping?

    /// 选择模式（工具栏按钮进入，Esc/完成退出）：瞬态不持久化。
    /// 状态放这里让工具栏按钮与墙容器共用同一事实源
    public var selectMode = false {
        didSet { if oldValue != selectMode { onUIUpdate?() } }
    }

    /// AppKit 侧的刷新通知（墙 reloadData + 状态栏）
    public var onUIUpdate: (() -> Void)?
    /// 索引进度回调（每次批次更新触发，比 onUIUpdate 密）：
    /// 0...1 = 真实进度；1 = 本轮完成（满格停留后淡出）；<0 = 失败（立即隐藏）
    public var onScanProgress: ((Double) -> Void)?

    private let repository: MediaRepository
    private let watcher = SourceWatcher()
    private var lastReloadAt = Date.distantPast
    private var pendingReloadTask: Task<Void, Never>?
    /// 扫描期整刷里程碑（每 4000 条重建一次墙，而非每批）
    private var scanMilestone = 0
    /// 后台重建代数（过期结果作废）
    private var reloadGeneration = 0

    public init() {
        // S-8：先体检，损坏则隔离重建（fatalError 仅剩"全新库也开不了"的极端环境兜底）
        if let note = MediaRepository.quarantineIfCorrupt() {
            databaseQuarantined = note
        }
        guard let repository = try? MediaRepository.default() else {
            fatalError("无法打开媒体库数据库（路径：\(LibraryPaths.database.path)）")
        }
        self.repository = repository
        if let saved = viewState(forKey: "appearance"),
           let mode = AppearanceMode(rawValue: saved) {
            appearanceMode = mode
        }
        if let saved = viewState(forKey: "filter"),
           let restored = LibraryFilter.from(persisted: saved) {
            filter = restored
        }
        if let saved = viewState(forKey: "typeFilter"),
           let restored = MediaTypeFilter(rawValue: saved) {
            typeFilter = restored
        }
        if let saved = viewState(forKey: "grouping"),
           let restored = LibraryGrouping(rawValue: saved) {
            groupingOverride = restored
        }
    }

    /// 生效的分组方式：用户覆盖优先；否则图库/收藏按时间、来源按文件夹
    public var effectiveGrouping: LibraryGrouping {
        groupingOverride ?? {
            switch filter {
            case .source: .byFolder
            case .all, .favorites: .byTime
            }
        }()
    }

    public func setGrouping(_ grouping: LibraryGrouping) {
        groupingOverride = grouping
        setViewState(grouping.rawValue, forKey: "grouping")
        reloadSections(force: true)
    }

    /// 分组方式 Picker 的可空绑定：nil = 跟随视图
    public func setGroupingOverride(_ grouping: LibraryGrouping?) {
        guard groupingOverride != grouping else { return }
        groupingOverride = grouping
        setViewState(grouping?.rawValue ?? "", forKey: "grouping")
        reloadSections(force: true)
    }

    /// 恢复"分组跟随视图"（清除覆盖，回到范围默认）
    public func resetGrouping() {
        groupingOverride = nil
        setViewState("", forKey: "grouping")
        reloadSections(force: true)
    }

    public func cycleTypeFilter() {
        let order: [MediaTypeFilter] = [.all, .photo, .video]
        let next = order[(order.firstIndex(of: typeFilter)! + 1) % order.count]
        setTypeFilter(next)
    }

    public func cycleGrouping() {
        let order: [LibraryGrouping] = [.byTime, .byFolder, .flat]
        let next = order[(order.firstIndex(of: effectiveGrouping)! + 1) % order.count]
        setGrouping(next)
    }

    public func setTypeFilter(_ type: MediaTypeFilter) {
        typeFilter = type
        setViewState(type.rawValue, forKey: "typeFilter")
        reloadSections(force: true)
    }

    /// 测试用：注入临时数据库仓库
    init(repository: MediaRepository) {
        self.repository = repository
    }

    public func start() {
        sources = (try? repository.listSources()) ?? []
        for source in sources {
            watcher.watch(sourceId: source.id, path: source.path) { [weak self] id in
                Task { @MainActor in await self?.rescan(id) }
            }
        }
        reloadSections(force: true)
    }

    // MARK: - 来源管理

    public func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "选择要加入媒体库的文件夹"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await addSource(at: url) }
    }

    public func addSource(at url: URL) async {
        // 提前去重：同一路径不重复入库
        if sources.contains(where: { $0.path == url.path }) { return }
        let bookmark = try? url.bookmarkData(
            options: .withSecurityScope, includingResourceValuesForKeys: nil
        )
        let id = (try? repository.insertSource(path: url.path, bookmark: bookmark)) ?? 0
        let source = SourceRecord(
            id: id, path: url.path, bookmark: bookmark, state: "scanning",
            createdAt: Date()
        )
        sources.append(source)
        await scan(source: source)
    }

    public func rescan(_ sourceId: Int64) async {
        guard let source = sources.first(where: { $0.id == sourceId }) else { return }
        await scan(source: source)
    }

    /// 重新索引：强制重提全部文件元数据（修库/刷新用），不触碰原始文件与缩略图缓存
    public func reindexSource(_ sourceId: Int64) async {
        guard let source = sources.first(where: { $0.id == sourceId }) else { return }
        await scan(source: source, force: true)
    }

    public func reindexAll() async {
        for source in sources {
            await scan(source: source, force: true)
        }
    }

    /// 重置媒体库：清除全部索引、来源与设置（原始文件不受影响，缩略图缓存一并清除）
    public func resetLibrary() {
        // S-2：先取消所有进行中的扫描，避免重置后扫描把数据写回
        for task in activeScanTasks.values { task.cancel() }
        activeScanTasks.removeAll()
        for source in sources {
            watcher.unwatch(sourceId: source.id)
        }
        try? repository.deleteAllSources()
        ThumbnailService.shared.clearCache()
        sources = []
        sections = []
        flatItems = []
        totalCount = 0
        galleryCount = 0
        sourceCounts = [:]
        favoriteCount = 0
        filter = .all
        try? repository.setViewState("", forKey: "filter")
        notifyUI()
    }

    // MARK: - 收藏

    /// 移除来源：删索引与侧栏条目，磁盘文件不动；若当前正看该来源则回到图库
    public func removeSource(_ sourceId: Int64) {
        // S-2：取消该来源进行中的扫描，避免移除后又写回
        activeScanTasks[sourceId]?.cancel()
        activeScanTasks[sourceId] = nil
        releaseAccess(sourceId: sourceId)
        watcher.unwatch(sourceId: sourceId)
        try? repository.deleteSource(id: sourceId)
        sources.removeAll(where: { $0.id == sourceId })
        if filter == .source(sourceId) {
            setFilter(.all)
        } else {
            reloadSections(force: true)
        }
    }

    /// 切换收藏（多选时：有任何未收藏项则全部收藏，否则全部取消）
    public func toggleFavorite(ids: Set<Int64>) {
        guard !ids.isEmpty else { return }
        let current = sections.flatMap(\.items).filter { ids.contains($0.id) }
        let target = current.contains(where: { !$0.isFavorite })
        try? repository.setFavorite(ids: Array(ids), isFavorite: target)

        // 原地更新内存数据（避免整墙 reload 闪动）
        var updatedSections = sections
        for sectionIndex in updatedSections.indices {
            for itemIndex in updatedSections[sectionIndex].items.indices
            where ids.contains(updatedSections[sectionIndex].items[itemIndex].id) {
                updatedSections[sectionIndex].items[itemIndex].isFavorite = target
            }
        }
        sections = updatedSections
        favoriteCount = (try? repository.favoriteCount()) ?? favoriteCount

        if filter == .favorites, !target {
            // 只看收藏模式下取消收藏：该条目应消失，整刷
            reloadSections(force: true)
        } else {
            notifyUI()
        }
    }

    /// 侧栏单选：点图库/收藏/来源直接切换，互斥
    public func setFilter(_ newFilter: LibraryFilter) {
        guard filter != newFilter else { return }
        filter = newFilter
        setViewState(newFilter.persisted, forKey: "filter")
        reloadSections(force: true)
    }

    // MARK: - 视图状态持久化

    public func viewState(forKey key: String) -> String? {
        try? repository.viewState(forKey: key)
    }

    public func setViewState(_ value: String, forKey key: String) {
        try? repository.setViewState(value, forKey: key)
    }

    // MARK: - 视频续播

    public func playbackSeconds(mediaId: Int64) -> Double? {
        try? repository.playbackSeconds(mediaId: mediaId)
    }

    public func setPlaybackSeconds(mediaId: Int64, seconds: Double) {
        try? repository.setPlaybackSeconds(mediaId: mediaId, seconds: seconds)
    }

    /// 清除缩略图缓存（内存 + 磁盘），下次浏览按需重新生成
    public func clearThumbnailCache() {
        ThumbnailService.shared.clearCache()
    }

    // MARK: - 外观（跟随系统/浅色/深色）

    public func setAppearanceMode(_ mode: AppearanceMode) {
        appearanceMode = mode
        setViewState(mode.rawValue, forKey: "appearance")
        NSApp.appearance = mode.nsAppearance
        // 清除窗口级外观覆盖：preferredColorScheme 强制态会把窗口钉死，
        // 切回跟随系统时不清除会出现「侧栏浅色/内容深色」的撕裂
        for window in NSApp.windows {
            window.appearance = nil
        }
    }

    /// 单个来源的一次扫描（可取消）：同一来源重复触发时先取消旧扫描。
    /// B-1 修复：扫描前先解析书签并启动安全作用域访问，失败标记离线，
    /// 绝不在不可读状态下做删除对账
    private func scan(source: SourceRecord, force: Bool = false) async {
        activeScanTasks[source.id]?.cancel()
        let task = Task { [weak self] in
            await self?.performScan(source: source, force: force)
            self?.activeScanTasks[source.id] = nil
        }
        activeScanTasks[source.id] = task
        await task.value
    }

    /// B-1：为来源恢复文件访问权限。书签可解析则启动安全作用域（保持到来源移除）；
    /// 无书签的旧记录退回路径存在性检查（非沙盒可用）。返回 false = 标记离线
    private func grantAccess(to source: SourceRecord) -> Bool {
        if scopedAccessURLs[source.id] != nil { return true }
        if let data = source.bookmark {
            var stale = false
            guard let url = try? URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) else {
                PWLog.scan.error("来源书签解析失败，标记离线")
                return false
            }
            // 非沙盒下 startAccessing 返回 false 属正常，路径仍可直接访问；沙盒下该调用即授权
            _ = url.startAccessingSecurityScopedResource()
            scopedAccessURLs[source.id] = url
            // 书签已过期：用当前 URL 刷新书签，避免每次启动都走降级路径
            if stale, let fresh = try? url.bookmarkData(options: .withSecurityScope) {
                try? repository.updateSourceBookmark(sourceId: source.id, bookmark: fresh)
            }
            return true
        }
        return FileManager.default.fileExists(atPath: source.path)
    }

    /// 释放来源的安全作用域访问（移除来源时调用）
    private func releaseAccess(sourceId: Int64) {
        if let url = scopedAccessURLs.removeValue(forKey: sourceId) {
            url.stopAccessingSecurityScopedResource()
        }
    }

    /// 把内存中的来源标记为离线（侧栏显示警示），并落库
    private func markSourceOffline(_ source: SourceRecord, note: String) {
        if let index = sources.firstIndex(where: { $0.id == source.id }) {
            sources[index].state = "offline"
        }
        try? repository.updateSourceState(source.id, state: "offline")
        progressText = note
        notifyUI()
    }

    private func performScan(source: SourceRecord, force: Bool) async {
        // B-1：访问授权失败 = 离线（盘没挂载/书签失效），跳过一切扫描与对账
        guard grantAccess(to: source) else {
            markSourceOffline(source, note: "来源暂时无法访问，已保留其索引（标记为离线）")
            onScanProgress?(-1)
            return
        }

        isScanning = true
        scanProgress = 0
        progressText = "扫描中…"
        scanMilestone = 0
        notifyUI()
        do {
            try await SourceScanner.scan(
                source: source,
                repository: repository,
                force: force,
                progress: { [weak self] done, total in
                    guard let self else { return }
                    // 进度文字由 SwiftUI Observation 自动刷新到副标题；
                    // 墙的整刷只在里程碑处做——扫描期每批全量 reload 是 O(n²)，
                    // 10 万条下会把吞吐从 1600/s 拖到 266/s
                    self.progressText = "索引中 \(done)/\(total)"
                    if total > 0 {
                        self.scanProgress = Double(done) / Double(total)
                        self.onScanProgress?(self.scanProgress)
                    }
                    if done - self.scanMilestone >= 4000 || done >= total {
                        self.scanMilestone = done
                        self.reloadSections(force: true)
                    }
                },
                onBatch: { _ in }
            )
            try? repository.updateSourceState(source.id, state: "online")
            if let index = sources.firstIndex(where: { $0.id == source.id }) {
                sources[index].state = "online"
            }
            scanProgress = 1
            progressText = ""
            onScanProgress?(1)
        } catch let error as SourceScanner.ScanError {
            // 离线/不可读：保留索引，标记离线；写库失败：给可感知提示
            isScanning = false
            switch error {
            case .rootUnreadable, .sourceOffline:
                PWLog.scan.error("扫描中止：\(error.localizedDescription, privacy: .public)")
                markSourceOffline(source, note: error.localizedDescription)
            case .writeFailures(let count):
                progressText = "扫描完成，但 \(count) 个批次写入失败（磁盘空间/媒体库可能异常）"
            }
            reloadSections(force: true)
            return
        } catch is CancellationError {
            // S-2：被取消（移除来源/重置/重复触发），静默收场
            isScanning = false
            progressText = ""
            return
        } catch {
            progressText = "扫描失败：\(error.localizedDescription)"
        }
        isScanning = false
        reloadSections(force: true)
    }

    // MARK: - 墙数据

    func reloadSections(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastReloadAt) > 0.5 else {
            scheduleTrailingReload()
            return
        }
        lastReloadAt = Date()
        // 查询与分区构建放后台（10 万行主线程要 1-2s，会造成切换筛选冻结）；
        // 代数计数防止过期结果覆盖新数据
        reloadGeneration += 1
        let generation = reloadGeneration
        let filter = self.filter
        let typeFilter = self.typeFilter
        let grouping = self.effectiveGrouping
        let sourcePaths = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0.path) })
        let repository = self.repository
        Task.detached(priority: .userInitiated) { [weak self] in
            let records: [MediaRecord]
            switch filter {
            case .all:
                records = (try? repository.allMedia(kind: typeFilter)) ?? []
            case .favorites:
                records = (try? repository.allMedia(favoritesOnly: true, kind: typeFilter)) ?? []
            case .source(let sourceId):
                records = (try? repository.allMedia(sourceId: sourceId, kind: typeFilter)) ?? []
            }
            let sections = LibraryStore.buildSections(
                from: records, sourcePaths: sourcePaths, grouping: grouping
            )
            let sourceCounts = (try? repository.countsBySource()) ?? [:]
            let galleryCount = (try? repository.mediaCount()) ?? 0
            let favoriteCount = (try? repository.favoriteCount()) ?? 0
            await MainActor.run { [weak self] in
                guard let self, self.reloadGeneration == generation else { return }
                self.sections = sections
                self.flatItems = sections.flatMap(\.items)
                self.totalCount = records.count
                self.galleryCount = galleryCount
                self.sourceCounts = sourceCounts
                self.favoriteCount = favoriteCount
                self.notifyUI()
            }
        }
    }

    private func scheduleTrailingReload() {
        guard pendingReloadTask == nil else { return }
        pendingReloadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard let self else { return }
            self.pendingReloadTask = nil
            self.reloadSections(force: true)
        }
    }

    private func throttledReload() {
        reloadSections(force: false)
    }

    private func notifyUI() {
        onUIUpdate?()
    }

    nonisolated static func buildSections(
        from records: [MediaRecord], sourcePaths: [Int64: String],
        grouping: LibraryGrouping = .byTime
    ) -> [WallSection] {
        let calendar = Calendar.current
        // 公共构造：排序（新→旧）+ WallItem
        func makeItems(_ records: [MediaRecord]) -> [WallItem] {
            records.map { record in
                let date = record.takenAt ?? record.fsModifiedAt
                let sourceName = URL(
                    fileURLWithPath: sourcePaths[record.sourceId] ?? ""
                ).lastPathComponent
                return WallItem(
                    id: record.id,
                    date: date,
                    isVideo: record.kind == .video,
                    envColor: record.envColor,
                    fileURL: record.fileURL(in: sourcePaths[record.sourceId] ?? ""),
                    filename: record.filename,
                    fsModifiedAt: record.fsModifiedAt,
                    takenAt: record.takenAt,
                    width: record.width,
                    height: record.height,
                    camera: record.camera,
                    lens: record.lens,
                    durationMs: record.durationMs,
                    isFavorite: record.isFavorite,
                    folderPath: record.folderPath,
                    sourceName: sourceName
                )
            }
        }

        switch grouping {
        case .byTime:
            var buckets: [Int: (title: String, records: [MediaRecord])] = [:]
            for record in records where record.kind != .unsupported {
                let date = record.takenAt ?? record.fsModifiedAt
                let components = calendar.dateComponents([.year, .month], from: date)
                guard let year = components.year, let month = components.month else { continue }
                let key = year * 12 + month
                if buckets[key] == nil {
                    buckets[key] = ("\(year)年\(month)月", [])
                }
                buckets[key]?.records.append(record)
            }
            return buckets
                .sorted { $0.key > $1.key }
                .map { key, bucket in
                    WallSection(
                        id: key, title: bucket.title,
                        items: makeItems(bucket.records).sorted { $0.date > $1.date }
                    )
                }
        case .byFolder:
            // 图库（多来源）先按来源一级归类；单来源直接按子文件夹
            struct FolderKey: Hashable { let source: String; let folder: String }
            var order: [FolderKey] = []
            var buckets: [FolderKey: [MediaRecord]] = [:]
            for record in records where record.kind != .unsupported {
                let sourceName = URL(
                    fileURLWithPath: sourcePaths[record.sourceId] ?? ""
                ).lastPathComponent
                let key = FolderKey(source: sourceName, folder: record.folderPath)
                if buckets[key] == nil {
                    order.append(key)
                    buckets[key] = []
                }
                buckets[key]?.append(record)
            }
            return order.compactMap { key in
                guard let bucketRecords = buckets[key] else { return nil }
                let title = key.folder == "（根目录）"
                    ? key.source
                    : "\(key.source) · \(key.folder)"
                return WallSection(
                    id: abs(key.source.hashValue ^ key.folder.hashValue),
                    title: title,
                    items: makeItems(bucketRecords).sorted { $0.date > $1.date }
                )
            }
        case .flat:
            return records.isEmpty ? [] : [WallSection(
                id: 0, title: "", items: makeItems(records)
            )]
        }
    }
}

extension MediaRecord {
    func fileURL(in sourcePath: String) -> URL {
        URL(fileURLWithPath: sourcePath).appendingPathComponent(relPath)
    }
}
