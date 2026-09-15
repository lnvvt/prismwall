import os
import AVFoundation
import AppKit

/// M2 Lightbox：真实照片/视频浏览 + 键盘导航 + 全屏轮播
/// 替换 S3 的假图 Spike；保留 shared element 飞行机制
@MainActor
final class ViewerController: NSObject {
    private static let curve = CAMediaTimingFunction(controlPoints: 0.32, 0.72, 0.0, 1.0)
    private static let duration: CFTimeInterval = 0.3

    enum Mode {
        case standard
        case slideshow
    }

    private(set) var isOpen = false
    private(set) var mode: Mode = .standard
    private var items: [WallItem] = []
    private(set) var index = 0
    private var overlay: FlightOverlayView?
    private var content: LightboxContentView?
    private var slideshowView: SlideshowOverlayView?
    private var originRect: NSRect = .zero
    private var keyMonitor: Any?
    private var slideshowTask: Task<Void, Never>?
    private(set) var slideshowPaused = false
    /// 轮播间隔（秒），S 键在 2/5/10 间循环
    private(set) var interval: Double = 5
    /// 播放进度：读取（续播）与回写（由上层落地到数据库）
    var playbackProvider: ((Int64) -> Double?)?
    var onPlaybackProgress: ((Int64, Double) -> Void)?
    /// 收藏切换：返回切换后的收藏状态（用于提示）
    var onToggleFavorite: ((WallItem) -> Bool)?
    /// 快捷键教学卡：仅首次打开查看器时展示（上层按库标记置位）
    var showsTeachingCard = false
    /// 右上角 ? 快捷键徽章开关（上层按用户设置传入）
    var showsShortcutBadge = true
    /// 教学卡/参考卡关闭回调（上层落库"已阅"）
    var onShortcutCardDismiss: (() -> Void)?

    var currentItem: WallItem? {
        items.indices.contains(index) ? items[index] : nil
    }

    func open(items: [WallItem], startItem: WallItem, fromView cardView: NSView, in hostView: NSView) {
        guard !isOpen, let contentRoot = hostView.window?.contentView ?? hostView as? NSView else { return }
        self.items = items
        index = items.firstIndex(where: { $0.id == startItem.id }) ?? 0
        isOpen = true
        originRect = cardView.convert(cardView.bounds, to: hostView)

        let overlay = FlightOverlayView(frame: hostView.bounds)
        overlay.autoresizingMask = [.width, .height]
        hostView.addSubview(overlay)
        self.overlay = overlay

        let cardSnapshot: CGImage?
        if let rep = cardView.bitmapImageRepForCachingDisplay(in: cardView.bounds) {
            cardView.cacheDisplay(in: cardView.bounds, to: rep)
            cardSnapshot = rep.cgImage
        } else {
            cardSnapshot = nil
        }
        overlay.flightLayer.contents = cardSnapshot
        overlay.flightLayer.contentsGravity = .resizeAspect
        overlay.flightLayer.backgroundColor = NSColor.black.cgColor

        let targetRect = overlay.bounds
        overlay.flightLayer.frame = targetRect
        let zoom = CABasicAnimation(keyPath: "frame")
        zoom.fromValue = NSValue(rect: originRect)
        zoom.toValue = NSValue(rect: targetRect)
        zoom.duration = Self.duration
        zoom.timingFunction = Self.curve
        overlay.flightLayer.add(zoom, forKey: "zoom")

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = Self.duration
        fade.timingFunction = Self.curve
        overlay.backdropLayer.add(fade, forKey: "fade")
        overlay.backdropLayer.opacity = 1

        installKeyMonitor()

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.duration) { [weak self] in
            self?.presentContent()
        }
    }

    func close() {
        guard let overlay, overlay.window != nil else { return }
        PWLog.viewer.debug("close viewer")
        isOpen = false
        removeKeyMonitor()
        stopSlideshowTimer()
        content?.stopPlayback()

        guard let rep = overlay.bitmapImageRepForCachingDisplay(in: overlay.bounds),
              let snapshot = rep.cgImage
        else {
            overlay.removeFromSuperview()
            self.overlay = nil
            content = nil
            return
        }
        overlay.cacheDisplay(in: overlay.bounds, to: rep)

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = Self.duration
        fade.timingFunction = Self.curve
        overlay.backdropLayer.add(fade, forKey: "fade")
        overlay.backdropLayer.opacity = 0

        overlay.flightLayer.contents = snapshot
        let zoom = CABasicAnimation(keyPath: "frame")
        zoom.fromValue = NSValue(rect: overlay.bounds)
        zoom.toValue = NSValue(rect: originRect)
        zoom.duration = Self.duration
        zoom.timingFunction = Self.curve
        overlay.flightLayer.add(zoom, forKey: "zoom-out")
        overlay.flightLayer.opacity = 1
        for subview in overlay.subviews {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.duration
                subview.animator().alphaValue = 0
            }
        }

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            self?.overlay?.removeFromSuperview()
            self?.overlay = nil
            self?.content = nil
        }
        CATransaction.commit()
    }

    /// 飞行结束后切入真实内容
    private func presentContent() {
        guard isOpen, let overlay, overlay.window != nil, let item = currentItem else { return }
        let content = LightboxContentView(
            frame: overlay.bounds,
            item: item,
            progressProvider: playbackProvider,
            onPlaybackProgress: onPlaybackProgress
        )
        content.autoresizingMask = [.width, .height]
        content.onClose = { [weak self] in self?.close() }
        content.alphaValue = 0
        // 首次使用：展示快捷键教学卡（关闭后落库，不再自动出现）
        if showsTeachingCard {
            showsTeachingCard = false
            content.showShortcutCard()
        }
        overlay.addSubview(content)
        self.content = content
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            content.animator().alphaValue = 1
        }
        overlay.flightLayer.opacity = 0
        prefetchAround(index: index)
    }

    // MARK: - 导航

    func navigate(_ delta: Int) {
        switch mode {
        case .standard:
            let target = index + delta
            guard items.indices.contains(target) else { return }
            index = target
            content?.transitionTo(currentItem)
            prefetchAround(index: index)
        case .slideshow:
            guard let next = nextPhotoIndex(from: index, direction: delta) else { return }
            index = next
            showSlideshowPhoto(crossfade: true)
        }
    }

    private func prefetchAround(index: Int) {
        let window = 3
        let neighbors = (1...window).flatMap { [index - $0, index + $0] }
            .filter(items.indices.contains)
            .map { items[$0] }
            .filter { !$0.isVideo }
        FullImageLoader.shared.prefetch(neighbors)
    }

    // MARK: - 轮播

    func enterSlideshow() {
        guard mode == .standard, let overlay else { return }
        // 当前是视频则跳到最近的照片
        if currentItem?.isVideo == true,
           let photoIndex = nextPhotoIndex(from: index, direction: 1) {
            index = photoIndex
        }
        mode = .slideshow
        slideshowPaused = false
        content?.stopPlayback()
        content?.isHidden = true
        overlay.flightLayer.opacity = 0
        let slideshow = SlideshowOverlayView(frame: overlay.bounds)
        slideshow.autoresizingMask = [.width, .height]
        overlay.addSubview(slideshow)
        self.slideshowView = slideshow
        showSlideshowPhoto(crossfade: false)
        startSlideshowTimer()
    }

    func exitSlideshow() {
        guard mode == .slideshow else { return }
        mode = .standard
        stopSlideshowTimer()
        slideshowView?.removeFromSuperview()
        slideshowView = nil
        content?.isHidden = false
        content?.transitionTo(currentItem)
    }

    func toggleSlideshow() {
        if mode == .slideshow { exitSlideshow() } else { enterSlideshow() }
    }

    func toggleSlideshowPause() {
        slideshowPaused.toggle()
    }

    func cycleInterval() {
        interval = interval == 2 ? 5 : (interval == 5 ? 10 : 2)
        content?.showHint(text: "轮播间隔：\(Int(interval)) 秒")
    }

    private func startSlideshowTimer() {
        slideshowTask?.cancel()
        slideshowTask = Task { [weak self] in
            while !Task.isCancelled {
                let interval = self?.interval ?? 5
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard let self, self.mode == .slideshow, !self.slideshowPaused else { continue }
                self.navigate(1)
            }
        }
    }

    private func stopSlideshowTimer() {
        slideshowTask?.cancel()
        slideshowTask = nil
    }

    private func showSlideshowPhoto(crossfade: Bool) {
        guard let item = currentItem else { return }
        FullImageLoader.shared.request(for: item, maxDim: 2560) { [weak self] image in
            self?.slideshowView?.show(image: image, crossfade: crossfade)
        }
    }

    private func nextPhotoIndex(from start: Int, direction: Int) -> Int? {
        guard !items.isEmpty else { return nil }
        var candidate = start
        for _ in 0..<items.count {
            candidate = (candidate + direction + items.count) % items.count
            if !items[candidate].isVideo { return candidate }
        }
        return nil
    }

    // MARK: - 键盘

    /// 返回 true 表示事件已消费
    func handleKeyDown(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let alt = flags.contains(.option)
        // 可重映射动作优先经 ShortcutManager 匹配（组合由设置页定义）
        if ShortcutManager.shared.matches(.playPause, event) {
            if mode == .slideshow {
                toggleSlideshowPause()
            } else if content?.isVideo == true {
                content?.togglePlayPause()
            } else {
                enterSlideshow()
            }
            return true
        }
        if ShortcutManager.shared.matches(.frameCapture, event) {
            if mode == .standard, content?.isVideo == true {
                content?.captureFrame()
                return true
            }
            return false
        }
        if ShortcutManager.shared.matches(.toggleMute, event) {
            content?.toggleMute()
            return true
        }
        if ShortcutManager.shared.matches(.rateUp, event) {
            content?.changeRate(by: 0.25)
            return true
        }
        if ShortcutManager.shared.matches(.rateDown, event) {
            content?.changeRate(by: -0.25)
            return true
        }
        if ShortcutManager.shared.matches(.toggleFavorite, event) {
            // F：收藏/取消收藏当前条目（照片/视频一致）
            if mode == .standard, let item = currentItem {
                let nowFavorite = onToggleFavorite?(item) ?? false
                content?.showHint(text: nowFavorite ? "已收藏 ♥" : "已取消收藏")
            }
            return true
        }
        switch event.keyCode {
        case 53: // Esc
            if mode == .slideshow { exitSlideshow() } else { close() }
            return true
        case 123: // ←
            if mode == .slideshow {
                navigate(-1)
            } else if content?.isVideo == true {
                if alt { navigate(-1) } else { content?.seek(by: -5) }
            } else {
                navigate(-1)
            }
            return true
        case 124: // →
            if mode == .slideshow {
                navigate(1)
            } else if content?.isVideo == true {
                if alt { navigate(1) } else { content?.seek(by: 5) }
            } else {
                navigate(1)
            }
            return true
        case 125, 126: // ↓ ↑：视频音量
            if mode == .standard, content?.isVideo == true {
                content?.changeVolume(by: event.keyCode == 126 ? 0.1 : -0.1)
                return true
            }
            return false
        case 36, 76: // Enter
            if mode == .standard {
                enterSlideshow()
                return true
            }
            return true
        case 34: // I：信息条
            content?.toggleInfo()
            return true
        case 1: // S：轮播间隔
            if mode == .slideshow {
                cycleInterval()
                return true
            }
            return false
        default:
            return false
        }
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isOpen else { return event }
            // 快捷键参考卡片展开时：任意按键先关闭卡片
            if self.content?.isShortcutCardShowing == true {
                self.content?.dismissShortcutCard()
                return nil
            }
            return self.handleKeyDown(event) ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}

// MARK: - 飞行层容器（S3 已验证的 makeBackingLayer 方案）

final class FlightOverlayView: NSView {
    let backdropLayer = CALayer()
    let flightLayer = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func makeBackingLayer() -> CALayer {
        let root = CALayer()
        backdropLayer.backgroundColor = NSColor.black.withAlphaComponent(0.98).cgColor
        backdropLayer.opacity = 0
        root.addSublayer(backdropLayer)
        root.addSublayer(flightLayer)
        return root
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.frame = bounds
        backdropLayer.frame = bounds
        CATransaction.commit()
    }
}

// MARK: - Lightbox 内容视图

final class LightboxContentView: NSView {
    private(set) var item: WallItem
    private var photoView: PhotoZoomView?
    private var videoView: VideoPlayerView?

    private let infoBox = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")
    private let hintBar = NSTextField(labelWithString: "")
    private let closeButton: NSButton = {
        let button = NSButton(image: NSImage(
            systemSymbolName: "xmark", accessibilityDescription: "关闭") ?? NSImage(),
            target: nil, action: nil)
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        button.layer?.cornerRadius = 12
        button.layer?.masksToBounds = true
        button.contentTintColor = .white
        button.toolTip = "关闭（Esc）"
        return button
    }()
    var onClose: (() -> Void)?
    private let helpBadge: NSButton = {
        let button = NSButton(image: NSImage(
            systemSymbolName: "questionmark", accessibilityDescription: "快捷键") ?? NSImage(),
            target: nil, action: nil)
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        button.layer?.cornerRadius = 11
        button.layer?.masksToBounds = true
        button.contentTintColor = .white
        button.toolTip = "查看快捷键"
        return button
    }()
    private var shortcutCard: ShortcutCardView?
    /// 是否显示快捷键徽章（上层按用户设置传入）
    var showsShortcutBadge = true { didSet { helpBadge.isHidden = !showsShortcutBadge } }
    /// 首次教学卡片（上层按"是否看过"传入）；卡片关闭时回调（用于落库）
    var onShortcutCardDismiss: (() -> Void)?
    var isShortcutCardShowing: Bool { shortcutCard?.isHidden == false }
    private var hintHideTask: Task<Void, Never>?

    var isVideo: Bool { item.isVideo }

    var playbackProvider: ((Int64) -> Double?)?
    var onPlaybackProgress: ((Int64, Double) -> Void)?

    init(
        frame frameRect: NSRect, item: WallItem,
        progressProvider: ((Int64) -> Double?)?,
        onPlaybackProgress: ((Int64, Double) -> Void)?
    ) {
        self.item = item
        self.playbackProvider = progressProvider
        self.onPlaybackProgress = onPlaybackProgress
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        infoBox.wantsLayer = true
        infoBox.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        infoBox.layer?.cornerRadius = 10
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        metaLabel.font = .systemFont(ofSize: 11, weight: .regular)
        metaLabel.textColor = .secondaryLabelColor
        infoBox.addSubview(titleLabel)
        infoBox.addSubview(metaLabel)

        hintBar.font = .systemFont(ofSize: 13, weight: .medium)
        hintBar.textColor = .white
        hintBar.wantsLayer = true
        hintBar.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        hintBar.layer?.cornerRadius = 10
        hintBar.layer?.borderWidth = 1
        hintBar.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor

        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        helpBadge.target = self
        helpBadge.action = #selector(helpBadgeClicked)
        for subview in [infoBox, hintBar, closeButton, helpBadge] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
        }
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: infoBox.topAnchor, constant: 8),
            titleLabel.leadingAnchor.constraint(equalTo: infoBox.leadingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: infoBox.trailingAnchor, constant: -12),

            metaLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            metaLabel.leadingAnchor.constraint(equalTo: infoBox.leadingAnchor, constant: 12),
            metaLabel.trailingAnchor.constraint(equalTo: infoBox.trailingAnchor, constant: -12),
            metaLabel.bottomAnchor.constraint(equalTo: infoBox.bottomAnchor, constant: -8),

            infoBox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            infoBox.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20),

            hintBar.centerXAnchor.constraint(equalTo: centerXAnchor),
            hintBar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            hintBar.heightAnchor.constraint(equalToConstant: 30),

            closeButton.widthAnchor.constraint(equalToConstant: 24),
            closeButton.heightAnchor.constraint(equalToConstant: 24),
            closeButton.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),

            helpBadge.widthAnchor.constraint(equalToConstant: 22),
            helpBadge.heightAnchor.constraint(equalToConstant: 22),
            helpBadge.topAnchor.constraint(equalTo: closeButton.bottomAnchor, constant: 10),
            helpBadge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -17),
        ])

        setItem(item, animated: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func closeClicked() { onClose?() }

    /// 切换条目（←→ 导航）：替换内容区并淡入
    func transitionTo(_ newItem: WallItem?) {
        guard let newItem else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.1
            infoBox.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.setItem(newItem, animated: true)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.1
                self?.infoBox.animator().alphaValue = 1
            }
        })
    }

    private func setItem(_ newItem: WallItem, animated: Bool) {
        item = newItem
        photoView?.removeFromSuperview()
        photoView = nil
        videoView?.removeFromSuperview()
        videoView = nil

        if newItem.isVideo {
            let video = VideoPlayerView(
                frame: bounds, item: newItem,
                progressProvider: playbackProvider,
                onPlaybackProgress: onPlaybackProgress
            )
            video.autoresizingMask = [.width, .height]
            addSubview(video, positioned: .below, relativeTo: infoBox)
            videoView = video
        } else {
            let photo = PhotoZoomView(frame: bounds, item: newItem)
            photo.autoresizingMask = [.width, .height]
            addSubview(photo, positioned: .below, relativeTo: infoBox)
            photoView = photo
        }
        updateInfo()
    }

    private func updateInfo() {
        titleLabel.stringValue = "\(item.isVideo ? "视频" : "照片") · \(item.filename)"
        var parts: [String] = []
        let date = item.takenAt ?? item.date
        parts.append(Self.dateFormatter.string(from: date))
        if item.width > 0 {
            parts.append("\(item.width)×\(item.height)")
        }
        if let camera = item.camera { parts.append(camera) }
        if let lens = item.lens { parts.append(lens) }
        if let ms = item.durationMs, ms > 0 {
            parts.append(Self.durationFormatter.string(from: Double(ms) / 1000) ?? "")
        }
        metaLabel.stringValue = parts.filter { !$0.isEmpty }.joined(separator: " · ")
        infoBox.isHidden = metaLabel.stringValue.isEmpty
    }

    func toggleInfo() {
        infoBox.isHidden.toggle()
    }

    /// 反馈提示（已收藏/已截帧等），2.5 秒后自动淡出
    func showHint(text: String) {
        hintBar.stringValue = text
        hintBar.alphaValue = 1
        hintHideTask?.cancel()
        hintHideTask = Task { [weak hintBar] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if !Task.isCancelled {
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.5
                    hintBar?.animator().alphaValue = 0
                }, completionHandler: nil)
            }
        }
    }

    // MARK: 快捷键参考卡片（首次教学 + ? 徽章唤起）

    func showShortcutCard() {
        if shortcutCard == nil {
            let card = ShortcutCardView()
            card.translatesAutoresizingMaskIntoConstraints = false
            card.onDismiss = { [weak self] in
                self?.dismissShortcutCard()
                self?.onShortcutCardDismiss?()
            }
            addSubview(card)
            NSLayoutConstraint.activate([
                card.centerXAnchor.constraint(equalTo: centerXAnchor),
                card.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
            shortcutCard = card
        }
        guard let card = shortcutCard else { return }
        card.isHidden = false
        card.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            card.animator().alphaValue = 1
        }
    }

    func dismissShortcutCard() {
        guard let card = shortcutCard, !card.isHidden else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            card.animator().alphaValue = 0
        }, completionHandler: { card.isHidden = true })
    }

    @objc private func helpBadgeClicked() { showShortcutCard() }

    // MARK: 播放控制转发

    func togglePlayPause() { videoView?.togglePlayPause() }
    func stopPlayback() { videoView?.pause() }
    func seek(by seconds: Double) { videoView?.seek(by: seconds) }
    func changeVolume(by delta: Double) { videoView?.changeVolume(by: delta) }
    func toggleMute() { videoView?.toggleMute() }
    func changeRate(by delta: Double) { videoView?.changeRate(by: delta) }
    func captureFrame() {
        guard let videoView else { return }
        videoView.captureCurrentFrame(filename: item.filename)
    }

    static func hintText(isVideo: Bool, mode: ViewerController.Mode) -> String {
        if mode == .slideshow {
            return "空格 暂停 · ←→ 切换 · S 间隔 · Esc 退出"
        }
        return isVideo
            ? "空格 播放/暂停 · ←→ ±5s · F 收藏 · ↑↓ 音量 · M 静音 · [ ] 变速 · C 截帧 · Esc 返回"
            : "←→ 切换 · 双击/捏合缩放 · F 收藏 · I 信息 · Enter 轮播 · Esc 返回"
    }

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute, .second]
        formatter.unitsStyle = .positional
        formatter.zeroFormattingBehavior = .pad
        return formatter
    }()
}

// MARK: - 照片缩放平移视图

final class PhotoZoomView: NSView {
    private let imageLayer = CALayer()
    private var item: WallItem
    private var scale: CGFloat = 1
    private var translation: CGPoint = .zero
    private var loadedFull = false

    init(frame frameRect: NSRect, item: WallItem) {
        self.item = item
        super.init(frame: frameRect)
        wantsLayer = true
        imageLayer.contentsGravity = .resizeAspect
        layer?.addSublayer(imageLayer)

        // 两段加载：缩略图秒开 → 全尺寸替换
        ThumbnailService.shared.request(for: item, maxDim: 480) { [weak self] image in
            guard let self, self.item.id == item.id, let image,
                  let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            else { return }
            self.applyIfCurrent(cg, full: false)
        }
        FullImageLoader.shared.request(for: item) { [weak self] image in
            guard let self, self.item.id == item.id, let image else { return }
            self.applyIfCurrent(image, full: true)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func applyIfCurrent(_ image: CGImage, full: Bool) {
        if full && !loadedFull {
            loadedFull = true
            imageLayer.contents = image
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.15)
            CATransaction.commit()
        } else if !loadedFull {
            imageLayer.contents = image
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        CATransaction.commit()
    }

    private func applyTransform() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var transform = CATransform3DIdentity
        transform = CATransform3DTranslate(transform, translation.x, translation.y, 0)
        transform = CATransform3DScale(transform, scale, scale, 1)
        imageLayer.transform = transform
        CATransaction.commit()
    }

    override func magnify(with event: NSEvent) {
        scale = min(6, max(1, scale * (1 + event.magnification)))
        if scale <= 1.001 { translation = .zero }
        applyTransform()
    }

    override func scrollWheel(with event: NSEvent) {
        guard scale > 1.001 else { return }
        translation.x += event.scrollingDeltaX
        translation.y += event.scrollingDeltaY
        let limitX = bounds.width * (scale - 1) / 2 + 40
        let limitY = bounds.height * (scale - 1) / 2 + 40
        translation.x = min(limitX, max(-limitX, translation.x))
        translation.y = min(limitY, max(-limitY, translation.y))
        applyTransform()
    }

    override func mouseUp(with event: NSEvent) {
        if event.clickCount == 2 {
            scale = scale > 1.001 ? 1 : 2.5
            if scale <= 1.001 { translation = .zero }
            applyTransform()
        }
        super.mouseUp(with: event)
    }
}

// MARK: - 视频播放视图

final class VideoPlayerView: NSView {
    private let player: AVPlayer
    private let playerLayer = AVPlayerLayer()
    private let slider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let timeLabel = NSTextField(labelWithString: "00:00 / 00:00")
    private let mediaItem: WallItem
    private var duration: Double = 0
    private var isScrubbing = false
    private var lastPersistedTime: Double = -1
    private let progressProvider: ((Int64) -> Double?)?
    var onPlaybackProgress: ((Int64, Double) -> Void)?
    nonisolated(unsafe) private var endObserver: NSObjectProtocol?

    init(
        frame frameRect: NSRect, item: WallItem,
        progressProvider: ((Int64) -> Double?)? = nil,
        onPlaybackProgress: ((Int64, Double) -> Void)? = nil
    ) {
        player = AVPlayer(url: item.fileURL)
        mediaItem = item
        self.progressProvider = progressProvider
        self.onPlaybackProgress = onPlaybackProgress
        super.init(frame: frameRect)
        wantsLayer = true
        // wantsLayer 不保证 backing layer 立即存在，显式创建（S3 教训）
        let backingLayer = CALayer()
        backingLayer.frame = bounds
        backingLayer.backgroundColor = NSColor.black.cgColor
        layer = backingLayer

        player.actionAtItemEnd = .none
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
        backingLayer.addSublayer(playerLayer)

        slider.isContinuous = true
        slider.controlSize = .small
        slider.target = self
        slider.action = #selector(sliderChanged)

        timeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        timeLabel.textColor = .secondaryLabelColor

        slider.translatesAutoresizingMaskIntoConstraints = false
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(slider)
        addSubview(timeLabel)
        NSLayoutConstraint.activate([
            slider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            slider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -110),
            slider.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -24),

            timeLabel.leadingAnchor.constraint(equalTo: slider.trailingAnchor, constant: 10),
            timeLabel.centerYAnchor.constraint(equalTo: slider.centerYAnchor),
        ])

        Task { [weak self] in
            let asset = AVURLAsset(url: item.fileURL)
            if let duration = try? await asset.load(.duration) {
                await MainActor.run {
                    self?.duration = duration.seconds
                    self?.slider.maxValue = duration.seconds
                    // 续播：有历史进度且不在片头/接近片尾，从上次位置继续
                    if let resumeAt = self?.progressProvider?(self?.mediaItem.id ?? 0),
                       resumeAt > 1, resumeAt < duration.seconds - 1 {
                        self?.player.seek(
                            to: CMTime(seconds: resumeAt, preferredTimescale: 600)
                        )
                        self?.syncUI(time: resumeAt)
                        let name = self?.mediaItem.filename ?? ""
                        PWLog.viewer.debug("续播 \(name, privacy: .private) @\(resumeAt, format: .fixed(precision: 1))")
                    }
                }
            }
        }

        player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated { self?.syncUI(time: time.seconds) }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.player.seek(to: .zero)
                self?.player.play()
                if let id = self?.mediaItem.id {
                    self?.onPlaybackProgress?(id, 0) // 播完重置进度
                }
            }
        }

        player.play()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }

    private func syncUI(time: Double) {
        guard !isScrubbing else { return }
        slider.doubleValue = time
        timeLabel.stringValue = "\(Self.format(time)) / \(Self.format(duration))"
        // 播放进度每 5s 回写一次（续播用）
        if abs(time - lastPersistedTime) > 5 {
            lastPersistedTime = time
            onPlaybackProgress?(mediaItem.id, time)
        }
    }

    @objc private func sliderChanged() {
        isScrubbing = true
        player.seek(
            to: CMTime(seconds: slider.doubleValue, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            self?.isScrubbing = false
        }
    }

    func togglePlayPause() {
        if player.timeControlStatus == .playing {
            player.pause()
            onPlaybackProgress?(mediaItem.id, player.currentTime().seconds)
        } else {
            player.play()
        }
    }

    func pause() {
        player.pause()
        onPlaybackProgress?(mediaItem.id, player.currentTime().seconds)
    }

    func seek(by seconds: Double) {
        let target = max(0, min(duration, player.currentTime().seconds + seconds))
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    func changeVolume(by delta: Double) {
        player.volume = max(0, min(1, player.volume + Float(delta)))
    }

    func toggleMute() {
        player.isMuted.toggle()
    }

    func changeRate(by delta: Double) {
        player.rate = max(0.25, min(4, player.rate + Float(delta)))
    }

    /// 截取当前帧存为 JPEG（保存到「下载」，文件名带时间戳）
    func captureCurrentFrame(filename: String) {
        let time = player.currentTime().seconds
        let sourceURL = mediaItem.fileURL
        let base = (filename as NSString).deletingPathExtension
        Task.detached(priority: .userInitiated) {
            let asset = AVURLAsset(url: sourceURL)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
            guard let cgImage = try? await generator.image(
                at: CMTime(seconds: max(0, time), preferredTimescale: 600)
            ).image else {
                PWLog.player.error("截帧失败：无法解码帧 t=\\(time, format: .fixed(precision: 2))")
                return
            }
            let rep = NSBitmapImageRep(cgImage: cgImage)
            guard let data = rep.representation(
                using: .jpeg, properties: [.compressionFactor: 0.92]
            ) else { return }

            // S-5：保存位置交给用户选择（沙盒下 SavePanel 本身就是授权通道），
            // 原子写防止中断产生坏文件。面板必须在主线程呈现
            await MainActor.run {
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.jpeg]
                panel.nameFieldStringValue = "\(base)-\(Int(time * 100)).jpg"
                panel.message = "选择视频截帧的保存位置"
                panel.begin { response in
                    guard response == .OK, let outputURL = panel.url else { return }
                    do {
                        try data.write(to: outputURL, options: .atomic)
                        PWLog.player.info("截帧已保存：\(outputURL.lastPathComponent, privacy: .private)")
                    } catch {
                        PWLog.player.error("截帧保存失败：\(error.localizedDescription, privacy: .public)")
                    }
                }
            }
        }
    }

    static func format(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

// MARK: - 轮播覆盖层（仅照片，交叉淡入淡出）

final class SlideshowOverlayView: NSView {
    private let bottomLayer = CALayer()
    private let topLayer = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        for layerItem in [bottomLayer, topLayer] {
            layerItem.contentsGravity = .resizeAspect
            layerItem.opacity = 1
            layer?.addSublayer(layerItem)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bottomLayer.frame = bounds
        topLayer.frame = bounds
        CATransaction.commit()
    }

    func show(image: CGImage?, crossfade: Bool) {
        guard let image else { return }
        guard crossfade else {
            bottomLayer.contents = image
            return
        }
        topLayer.contents = image
        topLayer.opacity = 0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.6
        topLayer.add(fade, forKey: "crossfade")
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            self?.bottomLayer.contents = image
            self?.topLayer.opacity = 0
        }
        CATransaction.commit()
    }
}

// MARK: - 快捷键参考卡片（首次教学 / ? 徽章唤起）

final class ShortcutCardView: NSVisualEffectView {
    var onDismiss: (() -> Void)?

    private let rows: [(String, String)] = [
        ("空格", "播放 / 暂停（视频）· 轮播（照片）"),
        ("←→", "切换 · ±5 秒"),
        ("↑↓", "音量"),
        ("F", "收藏 / 取消收藏"),
        ("I", "信息条"),
        ("M", "静音 · [ ] 变速"),
        ("C", "视频截帧"),
        ("Esc", "返回媒体墙"),
    ]

    init() {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor

        let title = NSTextField(labelWithString: "键盘快捷键")
        title.font = .systemFont(ofSize: 14, weight: .semibold)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(title)
        stack.setCustomSpacing(12, after: title)

        for (key, action) in rows {
            let keyLabel = NSTextField(labelWithString: key)
            keyLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
            keyLabel.textColor = .white
            keyLabel.wantsLayer = true
            keyLabel.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.14).cgColor
            keyLabel.layer?.cornerRadius = 5
            keyLabel.translatesAutoresizingMaskIntoConstraints = false
            keyLabel.widthAnchor.constraint(equalToConstant: 42).isActive = true
            keyLabel.heightAnchor.constraint(equalToConstant: 18).isActive = true
            keyLabel.alignment = .center

            let actionLabel = NSTextField(labelWithString: action)
            actionLabel.font = .systemFont(ofSize: 12)
            actionLabel.textColor = .labelColor

            let row = NSStackView(views: [keyLabel, actionLabel])
            row.orientation = .horizontal
            row.spacing = 10
            row.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(row)
        }

        let done = NSButton(title: "开始使用", target: self, action: #selector(dismiss))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        done.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(done)
        stack.setCustomSpacing(18, after: stack.arrangedSubviews.last ?? NSView())

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func dismiss() { onDismiss?() }
}
