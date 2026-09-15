import AppKit
import os
import UniformTypeIdentifiers

@MainActor
final class ThumbCellItem: NSCollectionViewItem {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("ThumbCell")

    /// 选择模式（工具栏开启）：单击=切换勾选，不打开 Lightbox。
    /// 静态标志：cell 复用频繁，逐实例通知反而繁琐；仅在主线程读写
    static var selectMode = false

    private let content = WallCellContentView()
    var onOpen: ((WallItem, NSView) -> Void)?
    var onToggleFavorite: ((WallItem) -> Void)?
    /// 选择模式下单击：交给容器切换勾选（程序化改 selectionIndexPaths）
    var onToggleSelect: (() -> Void)?
    private var item: WallItem?
    private var requestedKey: String?

    override func loadView() {
        view = content
    }

    func configure(_ media: WallItem) {
        self.item = media
        content.configure(item: media)
        content.onClick = { [weak self] in
            guard let self, let item = self.item else { return }
            self.onOpen?(item, self.view)
        }
        content.onToggleFavorite = { [weak self] in
            guard let self, let item = self.item else { return }
            self.onToggleFavorite?(item)
        }
        content.onToggleSelect = { [weak self] in
            self?.onToggleSelect?()
        }
        refreshSelectMode()

        // 缩略图异步加载：请求键与当前内容匹配才应用，避免 cell 复用错位
        let key = ThumbnailService.cacheKey(
            fileURL: media.fileURL, fsModifiedAt: media.fsModifiedAt, maxDim: 480
        )
        guard requestedKey != key else { return }
        requestedKey = key
        ThumbnailService.shared.request(for: media) { [weak self] image in
            guard let self, self.requestedKey == key, let image else { return }
            self.content.setImage(image)
        }
    }

    /// 选择模式切换或 cell 复用时刷新勾选圈显隐
    func refreshSelectMode() {
        content.applySelectMode(on: ThumbCellItem.selectMode, checked: isSelected)
    }

    override var isSelected: Bool {
        didSet {
            content.showsSelectionBorder = isSelected
            content.isSelectChecked = isSelected
        }
    }
}

/// 裁切填充的图片视图（Apple Photos 风格）
final class FillImageView: NSView {
    private let imageLayer = CALayer()
    var cornerRadius: CGFloat = 0 {
        didSet {
            imageLayer.cornerRadius = cornerRadius
            imageLayer.cornerCurve = .continuous
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        let root = CALayer()
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.masksToBounds = true
        root.addSublayer(imageLayer)
        layer = root
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setImage(_ image: NSImage) {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.15)
        imageLayer.contents = cg
        CATransaction.commit()
    }

    func clear() {
        imageLayer.contents = nil
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        CATransaction.commit()
    }
}

/// 卡片内容：环境主色占位 + 异步缩略图 + 视频角标 + 收藏心 + 文件名
/// 交互：单击打开（mouseUp 判定）、⌘⇧多选、拖拽出 App（文件承诺）、右键菜单
/// 选择模式下：单击=切换勾选圈，不打开
@MainActor
final class WallCellContentView: NSView, NSDraggingSource {
    var onClick: (() -> Void)?
    var onToggleFavorite: (() -> Void)?
    var onToggleSelect: (() -> Void)?
    var showsSelectionBorder = false {
        didSet {
            if oldValue != showsSelectionBorder { needsDisplay = true }
        }
    }
    /// 选择模式勾选圈状态（由 ThumbCellItem.isSelected 驱动）
    var isSelectChecked = false {
        didSet { refreshSelectBadge() }
    }
    private var isSelectMode = false

    private let imageView = FillImageView()
    private let badgeLabel = NSTextField(labelWithString: "▶")
    private let heartLabel = NSTextField(labelWithString: "♥")
    private let filenameLabel = NSTextField(labelWithString: "")
    /// 选择模式勾选圈：未选=半透明底空心圈，已选=强调色实心勾
    private let selectBadge = NSTextField(labelWithString: "✓")
    private var item: WallItem?
    private var mouseDownLocationInSelf: NSPoint?
    private var isDraggingFile = false
    /// 必须持有：NSFilePromiseProvider 对 delegate 是弱引用，
    /// 桥接若为局部变量会在拖拽过程中被释放，导致落点永远收不到文件
    private var filePromiseBridge: FilePromiseBridge?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.alphaValue = 0
        imageView.cornerRadius = DesignTokens.cardCornerRadius

        badgeLabel.font = .systemFont(ofSize: 11, weight: .bold)
        badgeLabel.textColor = .white
        badgeLabel.wantsLayer = true
        badgeLabel.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.5).cgColor
        badgeLabel.layer?.cornerRadius = 6
        badgeLabel.layer?.masksToBounds = true

        heartLabel.font = .systemFont(ofSize: 12, weight: .bold)
        heartLabel.textColor = DesignTokens.Color.accent
        heartLabel.wantsLayer = true
        heartLabel.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.4).cgColor
        heartLabel.layer?.cornerRadius = 6
        heartLabel.layer?.masksToBounds = true

        filenameLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        filenameLabel.textColor = .white
        filenameLabel.lineBreakMode = .byTruncatingMiddle
        filenameLabel.wantsLayer = true
        filenameLabel.layer?.shadowColor = NSColor.black.cgColor
        filenameLabel.layer?.shadowOpacity = 0.9
        filenameLabel.layer?.shadowRadius = 2

        selectBadge.font = .systemFont(ofSize: 10, weight: .bold)
        selectBadge.alignment = .center
        selectBadge.textColor = .white
        selectBadge.wantsLayer = true
        selectBadge.layer?.masksToBounds = true
        selectBadge.layer?.cornerRadius = 9
        selectBadge.isHidden = true

        for subview in [imageView, badgeLabel, heartLabel, filenameLabel, selectBadge] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
        }
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),

            badgeLabel.topAnchor.constraint(equalTo: imageView.topAnchor, constant: 6),
            badgeLabel.leadingAnchor.constraint(equalTo: imageView.leadingAnchor, constant: 6),

            heartLabel.topAnchor.constraint(equalTo: imageView.topAnchor, constant: 6),
            heartLabel.trailingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: -6),

            selectBadge.widthAnchor.constraint(equalToConstant: 18),
            selectBadge.heightAnchor.constraint(equalToConstant: 18),
            selectBadge.topAnchor.constraint(equalTo: imageView.topAnchor, constant: 6),
            selectBadge.trailingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: -6),

            filenameLabel.leadingAnchor.constraint(equalTo: imageView.leadingAnchor, constant: 8),
            filenameLabel.trailingAnchor.constraint(lessThanOrEqualTo: selectBadge.leadingAnchor, constant: -6),
            filenameLabel.bottomAnchor.constraint(equalTo: imageView.bottomAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(item: WallItem) {
        self.item = item
        imageView.clear()
        badgeLabel.isHidden = !item.isVideo
        heartLabel.isHidden = isSelectMode ? true : !item.isFavorite
        filenameLabel.stringValue = item.filename
        refreshSelectBadge()
        needsDisplay = true
    }

    /// 选择模式显隐：进入/退出时由容器对可见 cell 逐个调用
    func applySelectMode(on: Bool, checked: Bool) {
        isSelectMode = on
        isSelectChecked = checked
        // 选择模式用心形位置放勾选圈，心形让位（收藏态在收藏视图仍可见）
        heartLabel.isHidden = on ? true : !(item?.isFavorite ?? false)
        refreshSelectBadge()
    }

    private func refreshSelectBadge() {
        guard isSelectMode else {
            selectBadge.isHidden = true
            return
        }
        selectBadge.isHidden = false
        if isSelectChecked {
            selectBadge.stringValue = "✓"
            selectBadge.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
            selectBadge.layer?.borderWidth = 0
        } else {
            selectBadge.stringValue = ""
            selectBadge.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor
            selectBadge.layer?.borderWidth = 1.5
            selectBadge.layer?.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
        }
    }

    func setImage(_ image: NSImage) {
        imageView.setImage(image)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            imageView.animator().alphaValue = 1
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        // 占位色：环境主色，缩略图就绪前即上墙；亮度策略随外观
        let isDark = DesignTokens.Color.isDarkAppearance()
        let color: NSColor
        if let decoded = EnvColor.decode(item?.envColor) {
            color = isDark
                ? NSColor(
                    hue: decoded.hue, saturation: decoded.saturation,
                    brightness: max(0.35, decoded.brightness * 0.9), alpha: 1
                )
                : NSColor(
                    hue: decoded.hue, saturation: decoded.saturation * 0.7,
                    brightness: max(0.82, decoded.brightness * 1.15), alpha: 1
                )
        } else {
            color = isDark
                ? NSColor(calibratedWhite: 0.16, alpha: 1)
                : NSColor(calibratedWhite: 0.88, alpha: 1)
        }
        let cardRect = bounds.insetBy(dx: 3, dy: 3)
        let path = NSBezierPath(
            roundedRect: cardRect,
            xRadius: DesignTokens.cardCornerRadius,
            yRadius: DesignTokens.cardCornerRadius
        )
        color.setFill()
        path.fill()

        // 苹果系描边：常态发丝线，选中时系统强调色
        if showsSelectionBorder {
            NSColor.controlAccentColor.setStroke()
            path.lineWidth = 2.5
        } else {
            DesignTokens.Color.cardBorder.setStroke()
            path.lineWidth = 1
        }
        path.stroke()
    }

    // MARK: - 鼠标：单击打开 / ⌘⇧多选 / 选择模式勾选 / 拖拽出 App

    override func mouseDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // ⌘/⇧ 点击走 NSCollectionView 原生多选，不触发放大
        if flags.contains(.command) || flags.contains(.shift) {
            super.mouseDown(with: event)
            return
        }
        // 选择模式：拦截原生单击选中（原生会把选择重置为单选），由 mouseUp 切换勾选
        if ThumbCellItem.selectMode {
            mouseDownLocationInSelf = convert(event.locationInWindow, from: nil)
            return
        }
        mouseDownLocationInSelf = convert(event.locationInWindow, from: nil)
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isDraggingFile else { return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // ⌘/⇧ 拖动属于多选操作，不拖出文件
        if flags.contains(.command) || flags.contains(.shift) {
            super.mouseDragged(with: event)
            return
        }
        if let start = mouseDownLocationInSelf {
            let current = convert(event.locationInWindow, from: nil)
            let dx = current.x - start.x
            let dy = current.y - start.y
            if dx * dx + dy * dy > 25 { // 拖动超过 5pt 视为拖出文件
                PWLog.wall.debug("begin file drag")
                isDraggingFile = true
                beginFileDrag(with: event)
            }
        }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        PWLog.wall.debug("mouseUp clickCount=\(event.clickCount)")
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isMultiSelect = flags.contains(.command) || flags.contains(.shift)
        let dragged = isDraggingFile
        isDraggingFile = false
        let hadDown = mouseDownLocationInSelf != nil
        mouseDownLocationInSelf = nil
        // 选择模式：单击（非拖拽、无双击第二击）切换勾选；不转发 super（mouseDown 未转发）
        if ThumbCellItem.selectMode, !isMultiSelect {
            if !dragged, hadDown, event.clickCount == 1 {
                onToggleSelect?()
            }
            return
        }
        if !dragged, !isMultiSelect, event.clickCount >= 1 {
            onClick?()
        }
        super.mouseUp(with: event)
    }

    private func beginFileDrag(with event: NSEvent) {
        guard let item else { return }
        let ext = item.fileURL.pathExtension
        let utType = UTType(filenameExtension: ext)?.identifier ?? "public.data"
        let bridge = FilePromiseBridge(item: item)
        filePromiseBridge = bridge
        let promise = NSFilePromiseProvider(fileType: utType, delegate: bridge)
        let draggingItem = NSDraggingItem(pasteboardWriter: promise)
        // 拖拽影像：CGImage 需包成 NSImage，否则拖动时无视觉反馈（看起来像没生效）
        if let cg = cacheSnapshot() {
            let image = NSImage(
                cgImage: cg,
                size: NSSize(width: cg.width, height: cg.height)
            )
            draggingItem.setDraggingFrame(bounds, contents: image)
        } else {
            draggingItem.setDraggingFrame(bounds, contents: nil)
        }
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    private func cacheSnapshot() -> CGImage? {
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: rep)
        return rep.cgImage
    }

    // MARK: - 右键菜单

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let item else { return super.menu(for: event) }
        let menu = NSMenu()
        let favorite = NSMenuItem(
            title: item.isFavorite ? "取消收藏" : "收藏",
            action: #selector(toggleFavoriteAction), keyEquivalent: ""
        )
        favorite.target = self
        menu.addItem(favorite)
        let reveal = NSMenuItem(
            title: "在 Finder 中显示",
            action: #selector(revealInFinder), keyEquivalent: ""
        )
        reveal.target = self
        menu.addItem(reveal)
        let copy = NSMenuItem(
            title: "拷贝文件路径", action: #selector(copyFilePath), keyEquivalent: ""
        )
        copy.target = self
        menu.addItem(copy)
        return menu
    }

    @objc private func toggleFavoriteAction() {
        onToggleFavorite?()
    }

    @objc private func revealInFinder() {
        guard let item else { return }
        NSWorkspace.shared.activateFileViewerSelecting([item.fileURL])
    }

    @objc private func copyFilePath() {
        guard let item else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.fileURL.path, forType: .string)
    }

    // MARK: - 拖拽源与文件承诺

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor draggingContext: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    /// 文件承诺回调可能在后台线程，条目数据随 promise 桥接捕获
    private final class FilePromiseBridge: NSObject, NSFilePromiseProviderDelegate {
        let item: WallItem

        init(item: WallItem) {
            self.item = item
        }

        func filePromiseProvider(
            _ filePromiseProvider: NSFilePromiseProvider,
            fileNameForType fileType: String
        ) -> String {
            PWLog.wall.debug("promise fileName asked: \(self.item.filename, privacy: .private)")
            return self.item.filename
        }

        func filePromiseProvider(
            _ filePromiseProvider: NSFilePromiseProvider,
            writePromiseTo url: URL,
            completionHandler: @escaping (Error?) -> Void
        ) {
            PWLog.wall.debug("promise write to: \(url.lastPathComponent, privacy: .private)")
            do {
                try FileManager.default.copyItem(at: item.fileURL, to: url)
                completionHandler(nil)
                PWLog.wall.debug("promise write OK")
            } catch {
                PWLog.wall.error("promise write FAILED: \(error.localizedDescription, privacy: .public)")
                completionHandler(error)
            }
        }
    }
}
