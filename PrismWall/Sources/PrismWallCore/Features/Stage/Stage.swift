import AVFoundation
import AppKit
import Observation

/// M3 多视频舞台：焦点模型 + sync/free 双模式 + 宫格/一大多小布局
/// 同步引擎方案来自 S2 Spike 实测（齐发播放偏差 0-2ms、CPU 4.3%）
@MainActor
@Observable
final class StageController {
    enum Mode: String {
        case sync
        case free
    }

    enum Layout: String {
        case grid
        case hero
    }

    private(set) var mode: Mode = .sync
    private(set) var layout: Layout = .grid
    private(set) var focusIndex = 0
    private(set) var items: [WallItem] = []
    private(set) var isOpen = false
    private(set) var statusText = "准备中…"
    private(set) var players: [AVPlayer?] = []
    private var durations: [Double] = []
    private var volumes: [Double] = []
    private var focusMuted = false
    private var allMuted = false
    private(set) var outOfRange: [Bool] = []
    private var baseRate: Double = 1.0

    private var stageView: StageView?
    private var hostView: NSView?
    private var keyMonitor: Any?
    private var syncTask: Task<Void, Never>?
    private var lastItemIDs: [Int64] = []
    private var isScrubbing = false

    /// 主时钟锚点 = 第一个视频
    var anchorIndex: Int? { items.firstIndex(where: \.isVideo) }

    var anchorDuration: Double {
        guard let anchorIndex, durations.indices.contains(anchorIndex) else { return 0 }
        return durations[anchorIndex]
    }

    // MARK: - 开关

    func open(items: [WallItem], in hostView: NSView) {
        // 纯照片多选也进舞台（静态对比格），无视频时无播放行为
        let ids = items.map(\.id)
        let sameSelection = ids == lastItemIDs && !players.isEmpty

        if isOpen, sameSelection { return }
        self.items = items
        lastItemIDs = ids
        self.hostView = hostView

        if !sameSelection {
            mode = .sync
            layout = .grid
            focusIndex = 0
            focusMuted = false
            allMuted = false
            baseRate = 1.0
            rebuildPlayers()
        }

        if let stageView {
            hostView.addSubview(stageView)
        } else {
            let view = StageView(controller: self, frame: hostView.bounds)
            view.autoresizingMask = [.width, .height]
            hostView.addSubview(view)
            stageView = view
        }

        if !isOpen {
            isOpen = true
            installKeyMonitor()
        }
        applyFocusAudio(fade: 0)
        refreshOutOfRange()
        startSyncLoop()

        if mode == .sync {
            playAllWhenReady()
        }
        syncStatusText()
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        removeKeyMonitor()
        for player in players {
            player?.pause()
        }
        stageView?.removeFromSuperview()
        stageView = nil
    }

    private func rebuildPlayers() {
        players = items.map { item in
            item.isVideo ? AVPlayer(url: item.fileURL) : nil
        }
        for player in players {
            player?.actionAtItemEnd = .none
        }
        durations = items.map { _ in 0.0 }
        volumes = items.map { _ in 1.0 }
        outOfRange = items.map { _ in false }
        loadDurations()
    }

    private func loadDurations() {
        for (index, player) in players.enumerated() {
            guard let player, let item = player.currentItem else { continue }
            Task { [weak self] in
                let duration = (try? await item.asset.load(.duration)) ?? .zero
                await MainActor.run {
                    self?.durations[index] = duration.seconds
                    self?.stageView?.refreshTimeline()
                }
            }
        }
    }

    /// 全部就绪后同一 runloop tick 齐发播放（S2 验证方案）
    private func playAllWhenReady() {
        Task { [weak self] in
            let start = Date()
            while !Task.isCancelled {
                let allReady = self?.players.allSatisfy { $0?.currentItem?.status == .readyToPlay || $0 == nil } ?? false
                if allReady || Date().timeIntervalSince(start) > 8 { break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            guard let self, self.isOpen, self.mode == .sync else { return }
            for player in self.players {
                player?.play()
            }
            self.syncStatusText()
        }
    }

    // MARK: - 同步引擎

    private func startSyncLoop() {
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self, self.isOpen, self.mode == .sync,
                      let anchor = self.anchorIndex,
                      let anchorPlayer = self.players[anchor]
                else { continue }
                let mainTime0 = anchorPlayer.currentTime().seconds
                // 主时钟钳制：锚点播完即停表（actionAtItemEnd=.none 会让时钟越过媒体时长狂奔）
                let anchorDur = self.durations[anchor]
                var finished = false
                var mainTime = mainTime0
                if anchorDur > 0, mainTime0 > anchorDur {
                    mainTime = anchorDur
                    finished = true
                    if anchorPlayer.timeControlStatus == .playing {
                        anchorPlayer.pause()
                    }
                }
                var maxDrift: Double = 0
                for (index, player) in self.players.enumerated() {
                    guard let player, index != anchor else { continue }
                    let duration = self.durations[index]
                    let drift = player.currentTime().seconds - mainTime
                    let beyondRange = duration > 0 && mainTime > duration + 0.05
                    self.outOfRange[index] = beyondRange
                    if beyondRange {
                        if player.timeControlStatus == .playing {
                            player.pause()
                        }
                        continue
                    }
                    guard self.items[index].isVideo else { continue }
                    maxDrift = max(maxDrift, abs(drift))
                    // 主时钟停表（暂停/播完）：其它路跟随停下并对齐，不许脱缰
                    guard anchorPlayer.timeControlStatus == .playing else {
                        if player.timeControlStatus == .playing {
                            player.pause()
                        }
                        if abs(drift) > 0.25 {
                            player.seek(
                                to: CMTime(seconds: min(mainTime, duration), preferredTimescale: 600),
                                toleranceBefore: CMTime(seconds: 0.05, preferredTimescale: 600),
                                toleranceAfter: CMTime(seconds: 0.05, preferredTimescale: 600),
                                completionHandler: { _ in }
                            )
                        }
                        continue
                    }
                    if player.timeControlStatus != .playing {
                        player.play()
                    }
                    if abs(drift) > 0.2 {
                        player.seek(
                            to: CMTime(seconds: mainTime, preferredTimescale: 600),
                            toleranceBefore: CMTime(seconds: 0.05, preferredTimescale: 600),
                            toleranceAfter: CMTime(seconds: 0.05, preferredTimescale: 600),
                            completionHandler: { _ in }
                        )
                    } else if abs(drift) > 0.05 {
                        let correction = max(0.98, min(1.02, 1.0 - drift * 0.5))
                        player.rate = Float(self.baseRate * correction)
                    } else {
                        player.rate = Float(self.baseRate)
                    }
                }
                self.stageView?.refreshDim()
                if finished {
                    self.stageView?.setStatus(String(
                        format: "%@ · 已播完 · %d 路", self.mode.rawValue.uppercased(), self.items.count
                    ))
                } else {
                    self.stageView?.setStatus(String(
                        format: "%@ · 偏差 %.0fms · %d 路", self.mode.rawValue.uppercased(),
                        maxDrift * 1000, self.items.count
                    ))
                }
                self.stageView?.refreshTimeline()
            }
        }
    }

    private func refreshOutOfRange() {
        for (index, player) in players.enumerated() {
            guard let player else { continue }
            let duration = durations[index]
            outOfRange[index] = duration > 0 && player.currentTime().seconds > duration + 0.05
        }
        stageView?.refreshDim()
    }

    private func syncStatusText() {
        let anchorPlaying = anchorIndex.flatMap { players[$0]?.timeControlStatus } == .playing
        statusText = String(
            format: "%@ · %@ · %d 路", mode.rawValue.uppercased(),
            anchorPlaying ? "播放中" : "已暂停", items.count
        )
        stageView?.setStatus(statusText)
    }

    // MARK: - 焦点与音频

    func setFocus(_ index: Int) {
        guard items.indices.contains(index), index != focusIndex else { return }
        focusIndex = index
        stageView?.refreshFocus()
        applyFocusAudio(fade: 0.1)
        stageView?.needsLayout = true
    }

    func cycleFocus(_ step: Int) {
        guard !items.isEmpty else { return }
        let next = (focusIndex + step + items.count) % items.count
        setFocus(next)
    }

    /// 声音只属于焦点路（PRD F4），~100ms 步进淡变避免爆音
    private func applyFocusAudio(fade: Double) {
        for (index, player) in players.enumerated() {
            guard let player else { continue }
            let isFocus = index == focusIndex
            var volume = isFocus ? volumes[index] : 0
            if (isFocus && focusMuted) || allMuted {
                volume = 0
            }
            if fade <= 0.01 {
                player.volume = Float(volume)
            } else {
                fadeVolume(player, to: Float(volume), duration: fade)
            }
        }
    }

    nonisolated private func fadeVolume(_ player: AVPlayer, to target: Float, duration: Double) {
        let start = player.volume
        let steps = 8
        Task { [weak player] in
            for step in 1...steps {
                try? await Task.sleep(nanoseconds: UInt64(duration / Double(steps) * 1_000_000_000))
                guard let player else { return }
                let t = Float(step) / Float(steps)
                player.volume = start + (target - start) * t
            }
        }
    }

    // MARK: - 播放控制

    func togglePlayPause() {
        let anchorPlaying = anchorIndex.flatMap { players[$0]?.timeControlStatus } == .playing
        let ended = anchorDuration > 0 && anchorTime >= anchorDuration - 0.05
        if mode == .sync {
            if ended && !anchorPlaying {
                seekAllTo(0) // 播完后空格 = 从头再来
                for player in players { player?.play() }
            } else {
                for player in players {
                    if anchorPlaying {
                        player?.pause()
                    } else {
                        player?.play()
                    }
                }
            }
        } else if let player = focusPlayer, let index = focusVideoIndex {
            if durations[index] > 0, player.currentTime().seconds >= durations[index] - 0.05,
               player.timeControlStatus != .playing {
                player.seek(to: .zero)
            }
            if player.timeControlStatus == .playing {
                player.pause()
            } else {
                player.play()
            }
        }
        syncStatusText()
    }

    func seekAll(by seconds: Double) {
        let mainTime = anchorTime
        for (index, player) in players.enumerated() {
            guard let player else { continue }
            let target = max(0, min(durations[index], mainTime + seconds))
            player.seek(
                to: CMTime(seconds: target, preferredTimescale: 600),
                toleranceBefore: CMTime(seconds: 0.05, preferredTimescale: 600),
                toleranceAfter: CMTime(seconds: 0.05, preferredTimescale: 600)
            )
        }
        refreshOutOfRange()
    }

    func seekFocus(by seconds: Double) {
        guard let player = focusPlayer, let index = focusVideoIndex else { return }
        let target = max(0, min(durations[index], player.currentTime().seconds + seconds))
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: CMTime(seconds: 0.05, preferredTimescale: 600),
            toleranceAfter: CMTime(seconds: 0.05, preferredTimescale: 600)
        )
    }

    /// 进入 sync 时把所有路重新对齐主时钟
    private func resyncAll() {
        guard let anchor = anchorIndex, let anchorPlayer = players[anchor] else { return }
        let mainTime = anchorPlayer.currentTime().seconds
        for (index, player) in players.enumerated() {
            guard let player, index != anchor else { continue }
            player.seek(to: CMTime(seconds: min(mainTime, durations[index]), preferredTimescale: 600))
            if anchorPlayer.timeControlStatus == .playing {
                player.play()
            }
        }
    }

    var anchorTime: Double {
        guard let anchorIndex, let player = players[anchorIndex] else { return 0 }
        return player.currentTime().seconds
    }

    func scrub(to seconds: Double) {
        isScrubbing = false
        seekAllTo(seconds)
    }

    func beginScrub() {
        isScrubbing = true
    }

    private func seekAllTo(_ seconds: Double) {
        for (index, player) in players.enumerated() {
            guard let player else { continue }
            player.seek(
                to: CMTime(seconds: max(0, min(durations[index], seconds)), preferredTimescale: 600)
            )
        }
        refreshOutOfRange()
    }

    func changeRate(by delta: Double) {
        baseRate = max(0.25, min(4, baseRate + delta))
        if mode == .sync {
            for player in players {
                player?.rate = Float(baseRate)
            }
        } else {
            focusPlayer?.rate = Float(baseRate)
        }
    }

    func changeFocusVolume(by delta: Double) {
        guard let index = focusVideoIndex else { return }
        volumes[index] = max(0, min(1, volumes[index] + delta))
        focusMuted = false
        applyFocusAudio(fade: 0.05)
    }

    func toggleFocusMute() {
        focusMuted.toggle()
        applyFocusAudio(fade: 0.05)
    }

    func toggleAllMute() {
        allMuted.toggle()
        applyFocusAudio(fade: 0.05)
    }

    func toggleMode() {
        mode = mode == .sync ? .free : .sync
        if mode == .sync {
            resyncAll()
        }
        stageView?.refreshChrome()
        syncStatusText()
    }

    func toggleLayout() {
        layout = layout == .grid ? .hero : .grid
        stageView?.needsLayout = true
    }

    // MARK: - 键盘

    func handleKeyDown(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let alt = flags.contains(.option)
        let shift = flags.contains(.shift)

        // 可重映射动作经 ShortcutManager 匹配（⌥ 不参与匹配，保留 ⌥M 全部静音语义）
        if ShortcutManager.shared.matches(.playPause, event) {
            togglePlayPause()
            return true
        }
        if ShortcutManager.shared.matches(.toggleMute, event) {
            if alt { toggleAllMute() } else { toggleFocusMute() }
            return true
        }
        if ShortcutManager.shared.matches(.rateUp, event) {
            changeRate(by: 0.25)
            return true
        }
        if ShortcutManager.shared.matches(.rateDown, event) {
            changeRate(by: -0.25)
            return true
        }
        if ShortcutManager.shared.matches(.toggleLayout, event) {
            toggleLayout()
            return true
        }
        if ShortcutManager.shared.matches(.toggleSync, event) {
            toggleMode()
            return true
        }

        switch event.keyCode {
        case 53: // Esc
            close()
            return true
        case 123: // ←
            if mode == .sync { seekAll(by: shift ? -1 : -5) } else { seekFocus(by: shift ? -1 : -5) }
            return true
        case 124: // →
            if mode == .sync { seekAll(by: shift ? 1 : 5) } else { seekFocus(by: shift ? 1 : 5) }
            return true
        case 48: // Tab
            cycleFocus(shift ? -1 : 1)
            return true
        case 18, 19, 20, 21, 23, 22, 26, 28, 25: // 1-9
            let digitMap: [UInt16: Int] = [18: 0, 19: 1, 20: 2, 21: 3, 23: 4, 22: 5, 26: 6, 28: 7, 25: 8]
            if let digit = digitMap[event.keyCode], digit < items.count {
                setFocus(digit)
                return true
            }
            return false
        case 125, 126: // ↓ ↑
            changeFocusVolume(by: event.keyCode == 126 ? 0.1 : -0.1)
            return true
        default:
            return false
        }
    }

    private var focusPlayer: AVPlayer? {
        items.indices.contains(focusIndex) ? players[focusIndex] ?? nil : nil
    }

    private var focusVideoIndex: Int? {
        items.indices.contains(focusIndex) && items[focusIndex].isVideo ? focusIndex : nil
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isOpen else { return event }
            return self.handleKeyDown(event) ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}

// MARK: - 舞台视图

final class StageView: NSView {
    private weak var controller: StageController?
    private var cells: [StageCellView] = []
    private var cellsBuilt = false

    private let topBar = NSVisualEffectView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "")
    private let timelineSlider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private var isScrubbing = false

    init(controller: StageController, frame frameRect: NSRect) {
        self.controller = controller
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        topBar.material = .headerView
        topBar.blendingMode = .withinWindow
        topBar.state = .active

        statusLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        statusLabel.textColor = .secondaryLabelColor
        hintLabel.font = .systemFont(ofSize: 11, weight: .regular)
        hintLabel.textColor = .tertiaryLabelColor
        hintLabel.stringValue = "Tab/1-9 焦点 · 空格 播放 · ←→ seek · G 布局 · S 同步/独立 · M 静音 · Esc 返回"

        timelineSlider.isContinuous = true
        timelineSlider.controlSize = .small
        timelineSlider.target = self
        timelineSlider.action = #selector(sliderChanged)

        for subview in [topBar, statusLabel, hintLabel, timelineSlider] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
        }
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: topAnchor),
            topBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 36),

            statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            statusLabel.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),

            hintLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            hintLabel.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),

            timelineSlider.leadingAnchor.constraint(equalTo: statusLabel.trailingAnchor, constant: 16),
            timelineSlider.trailingAnchor.constraint(equalTo: hintLabel.leadingAnchor, constant: -16),
            timelineSlider.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
        ])
        rebuildCells()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setStatus(_ text: String) {
        statusLabel.stringValue = text
    }

    func rebuildCells() {
        guard let controller else { return }
        for cell in cells {
            cell.removeFromSuperview()
        }
        cells = controller.items.enumerated().map { index, item in
            let cell: StageCellView
            if item.isVideo, let player = controller.players[index] {
                cell = StageVideoCellView(player: player, index: index)
            } else {
                cell = StagePhotoCellView(item: item, index: index)
            }
            cell.translatesAutoresizingMaskIntoConstraints = false
            addSubview(cell, positioned: .below, relativeTo: topBar)
            return cell
        }
        cellsBuilt = true
        refreshFocus()
        refreshTimeline()
        needsLayout = true
    }

    @objc private func sliderChanged() {
        guard !isScrubbing else { return }
        isScrubbing = true
        controller?.scrub(to: timelineSlider.doubleValue)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            self.isScrubbing = false
        }
    }

    func refreshTimeline() {
        guard !isScrubbing, let controller else { return }
        timelineSlider.maxValue = controller.anchorDuration
        timelineSlider.doubleValue = controller.anchorTime
    }

    func refreshFocus() {
        guard let controller else { return }
        for (index, cell) in cells.enumerated() {
            cell.isFocused = index == controller.focusIndex
        }
    }

    func refreshDim() {
        guard let controller else { return }
        for (index, cell) in cells.enumerated() where controller.items[index].isVideo {
            cell.setDimmed(controller.outOfRange[index])
        }
    }

    func refreshChrome() {
        guard let controller else { return }
        // free 模式下主时间轴无意义，隐藏
        timelineSlider.isHidden = controller.mode != .sync
        setStatus(controller.statusText)
    }

    override func layout() {
        super.layout()
        guard let controller else { return }
        let bounds = bounds
        guard bounds.width > 50 else { return }
        let top = CGFloat(36)
        let area = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - top)
        let spacing = CGFloat(6)
        let count = cells.count
        guard count > 0 else { return }

        var rects: [NSRect] = []
        if controller.layout == .hero, count >= 2 {
            let focusRect = NSRect(
                x: 0, y: 0, width: area.width * 0.66 - spacing / 2, height: area.height
            )
            rects.append(focusRect)
            let sideWidth = area.width * 0.34 - spacing / 2
            let rest = count - 1
            let rows = rest
            let cellHeight = (area.height - spacing * CGFloat(rest - 1)) / CGFloat(max(rest, 1))
            for i in 0..<rest {
                let y = area.height - cellHeight - CGFloat(i) * (cellHeight + spacing)
                rects.append(NSRect(x: area.width * 0.66 + spacing / 2, y: y, width: sideWidth, height: cellHeight))
            }
        } else {
            let cols = count <= 1 ? 1 : (count <= 4 ? 2 : 3)
            let rows = Int(ceil(Double(count) / Double(cols)))
            let cellWidth = (area.width - spacing * CGFloat(cols - 1)) / CGFloat(cols)
            let cellHeight = (area.height - spacing * CGFloat(rows - 1)) / CGFloat(rows)
            for i in 0..<count {
                let row = i / cols
                let col = i % cols
                let x = CGFloat(col) * (cellWidth + spacing)
                let y = area.height - cellHeight - CGFloat(row) * (cellHeight + spacing)
                rects.append(NSRect(x: x, y: y, width: cellWidth, height: cellHeight))
            }
        }

        // hero 布局下焦点格放主位：交换焦点项与大格
        if controller.layout == .hero, count >= 2 {
            let focus = controller.focusIndex
            if focus != 0 {
                rects.swapAt(0, focus)
            }
        }

        for (index, cell) in cells.enumerated() where rects.indices.contains(index) {
            cell.frame = rects[index]
        }
    }
}

// MARK: - 单元格

class StageCellView: NSView {
    let badgeLabel: NSTextField
    private let dimLayer = CALayer()
    var isFocused = false {
        didSet { layer?.borderWidth = isFocused ? 2.5 : 1 }
    }

    init(index: Int) {
        badgeLabel = NSTextField(labelWithString: "\(index + 1)")
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
        layer?.borderWidth = 1

        badgeLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .bold)
        badgeLabel.textColor = .white
        badgeLabel.wantsLayer = true
        badgeLabel.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        badgeLabel.layer?.cornerRadius = 5
        badgeLabel.layer?.masksToBounds = true
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(badgeLabel)
        NSLayoutConstraint.activate([
            badgeLabel.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            badgeLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
        ])

        dimLayer.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor
        dimLayer.opacity = 0
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func makeBackingLayer() -> CALayer {
        let root = CALayer()
        root.addSublayer(dimLayer)
        return root
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dimLayer.frame = bounds
        CATransaction.commit()
    }

    func setDimmed(_ dimmed: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.3)
        dimLayer.opacity = dimmed ? 1 : 0
        CATransaction.commit()
    }
}

final class StageVideoCellView: StageCellView {
    private let playerLayer = AVPlayerLayer()

    init(player: AVPlayer, index: Int) {
        super.init(index: index)
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = NSColor.black.cgColor
        // makeBackingLayer 已建根层，追加视频层到根层最底
        layer?.insertSublayer(playerLayer, at: 0)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}

final class StagePhotoCellView: StageCellView {
    private let imageLayer = CALayer()

    init(item: WallItem, index: Int) {
        super.init(index: index)
        imageLayer.contentsGravity = .resizeAspect
        layer?.insertSublayer(imageLayer, at: 0)
        ThumbnailService.shared.request(for: item, maxDim: 720) { [weak self] image in
            guard let self, let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            else { return }
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.15)
            self.imageLayer.contents = cg
            CATransaction.commit()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        CATransaction.commit()
    }
}
