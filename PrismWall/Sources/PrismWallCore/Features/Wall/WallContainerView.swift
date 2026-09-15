import os
import AppKit

@MainActor
final class WallContainerView: NSView {
    private let material = NSVisualEffectView()
    private let collectionView = NSCollectionView()
    private let scrollView = NSScrollView()
#if DEBUG
    private let hud = FpsHud() // 发布构建整类剥离(Nit3)
#endif
    private let emptyIcon = NSImageView()
    private let emptyTitle = NSTextField(labelWithString: "媒体库是空的")
    private let emptyDetail = NSTextField(
        labelWithString: "点击右上角「添加文件夹」，或菜单栏 文件 → 添加文件夹…（⌘O）"
    )
    private var dataSource: WallDataSource
    private let viewer = ViewerController()
    private let stage = StageController()
    private var enterMonitor: Any?
    private let library: LibraryStore
    private var scrollTicks: [CFTimeInterval] = []
    private var lastHudUpdate: CFTimeInterval = 0
    /// 滚动位置恢复：启动时读入，数据首次就绪后定位一次；滚动时防抖持久化
    private var pendingScrollY: CGFloat = 0
    private var scrollRestored = false
    private var scrollPersistTask: Task<Void, Never>?

    /// 密度（卡片最小宽）：⌘+/⌘-/⌘0 或捏合调节，持久化到 view_state
    private var minCardWidth: CGFloat = DesignTokens.defaultMinCardWidth
    private var pinchAccumulator = 0.0
    private var gestureMonitor: Any?
    private let densityToast = NSTextField(labelWithString: "")
    private var densityToastTask: Task<Void, Never>?
    private var appearanceObservation: NSKeyValueObservation?

    /// 选择模式（library.selectMode 为事实源）+ 底部操作栏
    private var isSelectMode = false
    private let selectionBar = SelectionBarView()

    /// 索引进度条（顶部居中浮层，确定型：真实 done/total）
    private let indexProgress = IndexProgressView()

    init(library: LibraryStore) {
        self.library = library
        dataSource = WallDataSource(sections: library.sections)
        if let saved = Double(library.viewState(forKey: "wall.scrollY") ?? "") {
            pendingScrollY = CGFloat(saved)
        }
        if let saved = library.viewState(forKey: "wall.minCardWidth"),
           let value = Double(saved), value >= DesignTokens.densityFloor,
           value <= DesignTokens.densityCeiling {
            minCardWidth = CGFloat(value)
        }
        super.init(frame: .zero)

        // 苹果系底色：窗口材质（暗色下即系统深灰毛玻璃）
        material.material = .windowBackground
        material.blendingMode = .withinWindow
        material.state = .active
        material.translatesAutoresizingMaskIntoConstraints = false
        addSubview(material)

        // 流式布局：月份分区头原生支持；卡片尺寸按窗口列数动态精确铺满
        let layout = NSCollectionViewFlowLayout()
        layout.minimumInteritemSpacing = DesignTokens.gridSpacing
        layout.minimumLineSpacing = DesignTokens.gridSpacing
        layout.sectionInset = DesignTokens.gridMargins

        collectionView.collectionViewLayout = layout
        collectionView.dataSource = dataSource
        collectionView.delegate = dataSource
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.backgroundColors = [.clear]
        collectionView.register(
            ThumbCellItem.self,
            forItemWithIdentifier: ThumbCellItem.reuseIdentifier
        )
        collectionView.register(
            MonthHeaderView.self,
            forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
            withIdentifier: MonthHeaderView.reuseIdentifier
        )

        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.postsFrameChangedNotifications = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clipBoundsChanged),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        // 滚动区尺寸变化（窗口缩放/侧栏开合/滚动条出现压缩内容区）→ 重算列数
        // 注意必须监听 collectionView 本身：滚动条出现会压缩它而不改变 scrollView 的 frame
        collectionView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollViewFrameChanged),
            name: NSView.frameDidChangeNotification,
            object: collectionView
        )

        // 苹果风空状态：SF Symbol + 标题 + 说明
        emptyIcon.image = NSImage(
            systemSymbolName: "photo.on.rectangle.angled",
            accessibilityDescription: "空媒体库"
        )
        emptyIcon.contentTintColor = .tertiaryLabelColor
        emptyIcon.alphaValue = 0.9
        emptyTitle.font = .systemFont(ofSize: 15, weight: .medium)
        emptyTitle.textColor = .secondaryLabelColor
        emptyTitle.alignment = .center
        emptyDetail.font = .systemFont(ofSize: 12, weight: .regular)
        emptyDetail.textColor = .tertiaryLabelColor
        emptyDetail.alignment = .center

        #if DEBUG
        hud.translatesAutoresizingMaskIntoConstraints = false
        #endif
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        emptyIcon.translatesAutoresizingMaskIntoConstraints = false
        emptyTitle.translatesAutoresizingMaskIntoConstraints = false
        emptyDetail.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        #if DEBUG
        addSubview(hud)
        #endif
        addSubview(emptyIcon)
        addSubview(emptyTitle)
        addSubview(emptyDetail)
        NSLayoutConstraint.activate([
            material.topAnchor.constraint(equalTo: topAnchor),
            material.bottomAnchor.constraint(equalTo: bottomAnchor),
            material.leadingAnchor.constraint(equalTo: leadingAnchor),
            material.trailingAnchor.constraint(equalTo: trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),

            emptyIcon.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyIcon.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -36),
            emptyIcon.widthAnchor.constraint(equalToConstant: 52),
            emptyIcon.heightAnchor.constraint(equalToConstant: 44),

            emptyTitle.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyTitle.topAnchor.constraint(equalTo: emptyIcon.bottomAnchor, constant: 14),

            emptyDetail.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyDetail.topAnchor.constraint(equalTo: emptyTitle.bottomAnchor, constant: 6),
        ])

        #if DEBUG
        NSLayoutConstraint.activate([
            hud.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            hud.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
        ])
        #endif

        #if DEBUG
        hud.update(scrollFPS: 0, visibleItems: 0, totalItems: library.totalCount)
        // 营销截图等场景：PW_HIDE_FPS_HUD=1 隐藏性能 HUD（调试期默认仍显示）
        hud.isHidden = ProcessInfo.processInfo.environment["PW_HIDE_FPS_HUD"] != nil
        #endif

        dataSource.onOpen = { [weak self] item, view in
            self?.openLightbox(item: item, fromView: view)
        }
        dataSource.onToggleFavorite = { [weak self] item in
            self?.library.toggleFavorite(ids: [item.id])
            self?.syncWithLibrary()
        }
        dataSource.onToggleSelectAt = { [weak self] indexPath in
            self?.toggleSelectAt(indexPath)
        }
        dataSource.onSelectionChange = { [weak self] count in
            self?.selectionBar.apply(visible: self?.library.selectMode ?? false, count: count)
        }

        // 底部操作栏：布局 + 动作分发（浮层模式与密度提示气泡一致）
        selectionBar.onAction = { [weak self] action, sender in
            self?.handleSelectionAction(action, anchor: sender)
        }
        addSubview(selectionBar)
        NSLayoutConstraint.activate([
            selectionBar.centerXAnchor.constraint(equalTo: centerXAnchor),
            selectionBar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -24),
            selectionBar.heightAnchor.constraint(equalToConstant: 44),
        ])

        // 索引进度条：顶部居中；真实比例，满格停住后淡出
        addSubview(indexProgress)
        NSLayoutConstraint.activate([
            indexProgress.centerXAnchor.constraint(equalTo: centerXAnchor),
            indexProgress.topAnchor.constraint(equalTo: topAnchor, constant: 12),
        ])
        library.onScanProgress = { [weak self] fraction in
            guard let self, self.window != nil else { return }
            if fraction < 0 {
                self.indexProgress.isHidden = true
            } else {
                self.indexProgress.setProgress(fraction)
                if fraction >= 1 {
                    self.indexProgress.holdThenHide()
                }
            }
        }

        enterMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard let self else { return event }
            if self.viewer.isOpen || self.stage.isOpen { return event } // 打开的视图自己接管

            // 选择模式下 Esc 退出（优先于其他处理）
            if self.library.selectMode, event.keyCode == 53 {
                self.library.selectMode = false
                return nil
            }

            // ⌘+/⌘-/⌘0 密度调节（组合可自定义，经 ShortcutManager）
            if ShortcutManager.shared.matches(.zoomIn, event) {
                self.adjustDensity(bySteps: 1)
                return nil
            }
            if ShortcutManager.shared.matches(.zoomOut, event) {
                self.adjustDensity(bySteps: -1)
                return nil
            }
            if ShortcutManager.shared.matches(.zoomReset, event) {
                self.resetDensity()
                return nil
            }

            if ShortcutManager.shared.matches(.toggleFavorite, event) {
                MainActor.assumeIsolated { self.toggleFavoriteSelection() }
                return nil
            }
            if ShortcutManager.shared.matches(.cycleTypeFilter, event) {
                self.library.cycleTypeFilter()
                return nil
            }
            if event.keyCode == 36 || event.keyCode == 76 { // Return / Enter
                MainActor.assumeIsolated { self.enterSelection() }
                return nil
            }
            return event
        }

        library.onUIUpdate = { [weak self] in
            self?.syncWithLibrary()
        }
        // 播放进度：续播读取 + 定期回写
        viewer.playbackProvider = { [weak self] mediaId in
            self?.library.playbackSeconds(mediaId: mediaId)
        }
        viewer.onPlaybackProgress = { [weak self] mediaId, seconds in
            self?.library.setPlaybackSeconds(mediaId: mediaId, seconds: seconds)
        }
        // 查看器内 F 键收藏：作用于当前展示的条目（照片/视频一致）
        viewer.onToggleFavorite = { [weak self] item in
            guard let self else { return false }
            self.library.toggleFavorite(ids: [item.id])
            self.syncWithLibrary()
            return self.library.sections.flatMap(\.items)
                .first(where: { $0.id == item.id })?.isFavorite ?? false
        }
        // 快捷键教学卡：仅首次打开查看器时展示；? 徽章开关持久化
        viewer.showsTeachingCard = library.viewState(forKey: "viewer.teaching") == nil
        viewer.showsShortcutBadge = (library.viewState(forKey: "viewer.shortcutBadge") ?? "1") != "0"
        viewer.onShortcutCardDismiss = { [weak self] in
            self?.library.setViewState("1", forKey: "viewer.teaching")
        }

        // 密度提示气泡
        densityToast.font = .systemFont(ofSize: 12, weight: .medium)
        densityToast.textColor = .labelColor
        densityToast.wantsLayer = true
        densityToast.alignment = .center
        densityToast.layer?.backgroundColor =
            DesignTokens.Color.toastBackground().cgColor
        densityToast.layer?.cornerRadius = 9
        densityToast.layer?.masksToBounds = true
        densityToast.alphaValue = 0
        densityToast.translatesAutoresizingMaskIntoConstraints = false
        addSubview(densityToast)
        NSLayoutConstraint.activate([
            densityToast.centerXAnchor.constraint(equalTo: centerXAnchor),
            densityToast.topAnchor.constraint(equalTo: topAnchor, constant: 52),
            densityToast.heightAnchor.constraint(equalToConstant: 28),
            densityToast.widthAnchor.constraint(greaterThanOrEqualToConstant: 130),
        ])

        // 系统外观切换（跟随系统模式）→ 重绘含硬编码色的部分
        appearanceObservation = NSApp.observe(
            \.effectiveAppearance, options: [.new]
        ) { [weak self] _, _ in
            DispatchQueue.main.async { self?.refreshTheme() }
        }

        // 触控板捏合调密度
        gestureMonitor = NSEvent.addLocalMonitorForEvents(matching: .gesture) {
            [weak self] event in
            guard let self, !self.viewer.isOpen, !self.stage.isOpen,
                  event.window === self.window
            else { return event }
            self.pinchAccumulator += event.magnification
            if abs(self.pinchAccumulator) > 0.12 {
                let step = self.pinchAccumulator > 0 ? 1 : -1
                self.pinchAccumulator = 0
                self.adjustDensity(bySteps: step)
            }
            return event
        }

        syncWithLibrary()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        PWLog.wall.debug("wall attached, sections=\(self.dataSource.sections.count) items=\(self.library.totalCount)")
        window?.makeFirstResponder(collectionView)
    }

    override func layout() {
        super.layout()
        updateGridLayout()
    }

    /// 外观变化：layer 色重设 + 全部卡片重绘（draw 内动态色按新外观解析）
    private func refreshTheme() {
        densityToast.layer?.backgroundColor = DesignTokens.Color.toastBackground().cgColor
        indexProgress.refreshTheme()
        for case let cell as ThumbCellItem in collectionView.visibleItems() {
            cell.view.needsDisplay = true
        }
        needsDisplay = true
    }

    /// 按内容区宽度计算列数，卡片精确铺满行宽（消灭大间隔），随窗口缩放与密度缩放
    private func updateGridLayout() {
        guard let flow = collectionView.collectionViewLayout as? NSCollectionViewFlowLayout
        else { return }
        let usable = currentUsableWidth()
        guard usable > 80 else { return }
        let spacing = DesignTokens.gridSpacing
        // 列数计算加 1pt 宽容，防止「刚好放下」被浮点边界判成放不下而掉档
        var cols = max(2, Int((usable + 1 + spacing) / (minCardWidth + spacing)))
        // 卡片宽度向下取整整数 pt，保证 N 卡 + 缝 严格 ≤ 行宽（否则 flow 会把行摊大）
        var cardWidth = ((usable - spacing * CGFloat(cols - 1)) / CGFloat(cols)).rounded(.down)
        // 单卡过大时补一列，避免少量条目被放大成巨卡
        while cardWidth > DesignTokens.maxCardWidth {
            cols += 1
            cardWidth = ((usable - spacing * CGFloat(cols - 1)) / CGFloat(cols)).rounded(.down)
        }
        flow.itemSize = NSSize(width: cardWidth, height: cardWidth / DesignTokens.cardAspect)
        flow.invalidateLayout()
    }

    private func currentUsableWidth() -> CGFloat {
        // 必须用 collectionView 实际宽度：scrollView.contentSize 会虚报
        // （滚动条预留 17pt 导致 3 列差一点放不下 → flow 每行掉成 2 列摊大间隔）
        collectionView.bounds.width
            - DesignTokens.gridMargins.left - DesignTokens.gridMargins.right
    }

    /// ⌘+/⌘-：直接加减一列（每次按下必有可见变化，避免列数平台内按了没反应）
    func adjustDensity(bySteps steps: Int) {
        let usable = currentUsableWidth()
        guard usable > 80 else { return }
        let spacing = DesignTokens.gridSpacing
        var cols = max(2, Int((usable + spacing) / (minCardWidth + spacing)))
        var cardWidth = (usable - spacing * CGFloat(cols - 1)) / CGFloat(cols)
        while cardWidth > DesignTokens.maxCardWidth {
            cols += 1
            cardWidth = (usable - spacing * CGFloat(cols - 1)) / CGFloat(cols)
        }
        // ⌘+ 允许降到 1 列，由 maxCardWidth 检查决定是否触发"已是最大"提示
        let newCols = max(1, cols - steps)
        let newWidth = (usable - spacing * CGFloat(newCols - 1)) / CGFloat(newCols)
        if steps > 0, newWidth > DesignTokens.maxCardWidth {
            showDensityToast(text: "已是最大卡片")
            return
        }
        if steps < 0, newWidth < DesignTokens.densityFloor {
            showDensityToast(text: "已是最小卡片")
            return
        }
        minCardWidth = newWidth
        persistDensity()
        updateGridLayout()
        showDensityToast()
    }

    func resetDensity() {
        minCardWidth = DesignTokens.defaultMinCardWidth
        persistDensity()
        updateGridLayout()
        showDensityToast()
    }

    private func persistDensity() {
        library.setViewState(String(format: "%.0f", minCardWidth), forKey: "wall.minCardWidth")
    }

    private func showDensityToast(text: String? = nil) {
        densityToast.stringValue = text
            ?? String(format: "卡片 ≈ %.0f pt（⌘0 恢复默认）", minCardWidth)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            densityToast.animator().alphaValue = 1
        }
        densityToastTask?.cancel()
        densityToastTask = Task { [weak densityToast] in
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            guard !Task.isCancelled else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.4
                densityToast?.animator().alphaValue = 0
            }, completionHandler: nil)
        }
    }

    private func syncWithLibrary() {
        // 关键：不替换 dataSource 对象，只原地更新数据再 reload（见 WallDataSource 注释）
        // reloadData 在 section 数减少时会残留旧分组头视图，先显式移除
        for case let header as MonthHeaderView
        in collectionView.subviews.flatMap({ $0.subviews }) {
            header.removeFromSuperview()
        }
        dataSource.update(sections: library.sections)
        collectionView.reloadData()
        updateGridLayout()
        restoreScrollOnceIfNeeded()

        let isEmpty = library.sections.isEmpty
        for view in [emptyIcon, emptyTitle, emptyDetail] {
            view.isHidden = !isEmpty
        }
        if library.isScanning && isEmpty {
            emptyTitle.stringValue = "索引中…"
            emptyDetail.stringValue = library.progressText
        } else {
            emptyTitle.stringValue = "媒体库是空的"
            emptyDetail.stringValue = "点击右上角「添加文件夹」，或菜单栏 文件 → 添加文件夹…（⌘O）"
        }
        #if DEBUG
        hud.update(
            scrollFPS: scrollTicks.count,
            visibleItems: collectionView.indexPathsForVisibleItems().count,
            totalItems: library.totalCount
        )
        #endif
        applySelectMode()
    }

    // MARK: - 选择模式（library.selectMode 为事实源，工具栏/菜单/Esc/完成 均汇聚于此）

    private func applySelectMode() {
        let on = library.selectMode
        let changed = on != isSelectMode
        isSelectMode = on
        ThumbCellItem.selectMode = on
        if changed {
            collectionView.deselectAll(nil)
            // reloadData 后可见列表即全部 cell：configure 已带最新模式，此处只兜底非复用实例
            for case let cell as ThumbCellItem in collectionView.visibleItems() {
                cell.refreshSelectMode()
            }
        }
        selectionBar.apply(visible: on, count: collectionView.selectionIndexPaths.count)
    }

    /// 选择模式单击：程序化切换勾选（不触发 delegate，计数手动刷新）
    private func toggleSelectAt(_ indexPath: IndexPath) {
        var selection = collectionView.selectionIndexPaths
        if selection.contains(indexPath) {
            selection.remove(indexPath)
        } else {
            selection.insert(indexPath)
        }
        collectionView.selectionIndexPaths = selection
        selectionBar.apply(visible: true, count: selection.count)
    }

    /// 当前选中项（按分区/位置排序，与 Enter 进舞台的顺序一致）
    private var selectedItems: [WallItem] {
        collectionView.selectionIndexPaths.sorted {
            ($0.section, $0.item) < ($1.section, $1.item)
        }.compactMap { ip in
            let sections = dataSource.sections
            guard ip.section < sections.count, ip.item < sections[ip.section].items.count
            else { return nil }
            return sections[ip.section].items[ip.item]
        }
    }

    private func handleSelectionAction(_ action: SelectionBarView.Action, anchor: NSView) {
        let items = selectedItems
        switch action {
        case .toggleFavorite:
            library.toggleFavorite(ids: Set(items.map(\.id)))
            syncWithLibrary()
        case .stage:
            guard items.count >= 2 else { return }
            enterSelection()
        case .finder:
            NSWorkspace.shared.activateFileViewerSelecting(items.map(\.fileURL))
        case .copyPath:
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            for path in items.map({ $0.fileURL.path }) {
                pasteboard.setString(path, forType: .string)
            }
        case .share:
            let picker = NSSharingServicePicker(items: items.map(\.fileURL))
            picker.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        case .done:
            library.selectMode = false
        }
    }

    @objc private func clipBoundsChanged(_ notification: Notification) {
        handleScrollFrame()
    }

    @objc private func scrollViewFrameChanged(_ notification: Notification) {
        updateGridLayout()
    }

    private func handleScrollFrame() {
        let now = CFAbsoluteTimeGetCurrent()
        scrollTicks.append(now)
        while let first = scrollTicks.first, now - first > 1.0 {
            scrollTicks.removeFirst()
        }
        persistScrollPositionThrottled()
        guard now - lastHudUpdate > 0.5 else { return }
        lastHudUpdate = now
        #if DEBUG
        hud.update(
            scrollFPS: scrollTicks.count,
            visibleItems: collectionView.indexPathsForVisibleItems().count,
            totalItems: library.totalCount
        )
        #endif
    }

    /// 滚动停止 0.6s 后把滚动位置写入 view_state（重启恢复用）
    private func persistScrollPositionThrottled() {
        scrollPersistTask?.cancel()
        let y = scrollView.contentView.bounds.origin.y
        scrollPersistTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard let self, !Task.isCancelled else { return }
            self.library.setViewState(String(format: "%.0f", y), forKey: "wall.scrollY")
        }
    }

    /// 数据首次就绪后恢复上次滚动位置（仅一次）
    private func restoreScrollOnceIfNeeded() {
        guard !scrollRestored, !library.sections.isEmpty else { return }
        scrollRestored = true
        guard pendingScrollY > 0 else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let document = self.scrollView.documentView else { return }
            let maxY = max(0, document.bounds.height - self.scrollView.contentView.bounds.height)
            let y = min(self.pendingScrollY, maxY)
            self.scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
            self.scrollView.reflectScrolledClipView(self.scrollView.contentView)
            PWLog.wall.debug("scroll restored to \(y, format: .fixed(precision: 0))")
        }
    }

    /// Enter 分流：多选进舞台（照片静态对比 / 视频同播），单选进 Lightbox
    private func enterSelection() {
        let selection = collectionView.selectionIndexPaths.sorted {
            ($0.section, $0.item) < ($1.section, $1.item)
        }
        if selection.count > 1 {
            let items = selection.compactMap {
                dataSource.sections.indices.contains($0.section)
                    ? dataSource.sections[$0.section].items.indices.contains($0.item)
                        ? dataSource.sections[$0.section].items[$0.item] : nil
                    : nil
            }
            if !items.isEmpty {
                stage.open(items: items, in: self)
                return
            }
        }
        openLightboxForSelection()
    }

    /// F 键：把当前选中项全部收藏/取消收藏
    private func toggleFavoriteSelection() {
        let ids = Set(
            collectionView.selectionIndexPaths.compactMap {
                dataSource.sections.indices.contains($0.section)
                    ? dataSource.sections[$0.section].items.indices.contains($0.item)
                        ? dataSource.sections[$0.section].items[$0.item].id : nil
                    : nil
            }
        )
        library.toggleFavorite(ids: ids)
        syncWithLibrary()
    }

    /// 鼠标点击或 Enter：卡片快照后飞往 Lightbox（shared element）
    private func openLightboxForSelection() {
        guard !viewer.isOpen && !stage.isOpen,
              let indexPath = collectionView.selectionIndexPaths.first,
              let cell = collectionView.item(at: indexPath)
        else { return }
        let item = dataSource.sections[indexPath.section].items[indexPath.item]
        openLightbox(item: item, fromView: cell.view)
    }

    private func openLightbox(item: WallItem, fromView cardView: NSView) {
        guard !viewer.isOpen && !stage.isOpen else { return }
        viewer.open(
            items: library.flatItems, startItem: item, fromView: cardView, in: self
        )
    }
}
