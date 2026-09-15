import AppKit

/// 索引进度条：主界面顶部居中浮层。
/// 确定型进度（done/total 真实比例），数字与填充同步变化，
/// 到 100% 短暂停留后淡出——无循环动画。
/// 颜色全部走系统动态色 + 毛玻璃材质，深浅外观自动适配。
@MainActor
final class IndexProgressView: NSVisualEffectView {
    private let titleLabel = NSTextField(labelWithString: "正在索引")
    private let percentLabel = NSTextField(labelWithString: "0%")
    private let track = NSView()
    private let fill = NSView()
    private var fillWidthConstraint: NSLayoutConstraint!
    private var fraction: Double = 0
    private var hideTask: Task<Void, Never>?

    init() {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        translatesAutoresizingMaskIntoConstraints = false
        alphaValue = 0
        isHidden = true

        titleLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
        titleLabel.textColor = .labelColor
        percentLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        percentLabel.textColor = .secondaryLabelColor
        percentLabel.alignment = .right

        for view in [track, fill] {
            view.wantsLayer = true
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        applyThemeColors()

        let header = NSStackView(views: [titleLabel, percentLabel])
        header.orientation = .horizontal
        header.distribution = .fill
        header.spacing = 8
        header.translatesAutoresizingMaskIntoConstraints = false
        // 让百分比贴右：中轴拉伸标题侧
        header.setHuggingPriority(.defaultLow, for: .horizontal)

        addSubview(header)
        addSubview(track)
        track.addSubview(fill)

        fillWidthConstraint = fill.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 264),

            header.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),

            track.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            track.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            track.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            track.heightAnchor.constraint(equalToConstant: 5),
            track.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),

            fill.topAnchor.constraint(equalTo: track.topAnchor),
            fill.bottomAnchor.constraint(equalTo: track.bottomAnchor),
            fill.leadingAnchor.constraint(equalTo: track.leadingAnchor),
            fillWidthConstraint,
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        // 初次布局/尺寸变化时按当前比例直接就位（无动画），避免首帧停在 0
        fillWidthConstraint.constant = track.bounds.width * fraction
    }

    /// 外观切换时重解析动态色（容器 refreshTheme 调用）
    func refreshTheme() {
        applyThemeColors()
    }

    private func applyThemeColors() {
        layer?.borderColor = NSColor.separatorColor.cgColor
        track.wantsLayer = true
        track.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.6).cgColor
        track.layer?.cornerRadius = 2.5
        fill.wantsLayer = true
        fill.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        fill.layer?.cornerRadius = 2.5
    }

    /// fraction：0...1 真实进度。填充宽度与百分比数字同步更新；
    /// 每次更新重置隐藏计时——连续索引期间保持可见
    func setProgress(_ value: Double) {
        hideTask?.cancel()
        hideTask = nil
        if isHidden {
            isHidden = false
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                animator().alphaValue = 1
            }
        }
        fraction = max(0, min(1, value))
        percentLabel.stringValue = "\(Int((fraction * 100).rounded()))%"
        let trackWidth = track.bounds.width
        guard trackWidth > 0 else { return } // 尚未布局：layout() 会按 fraction 就位
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            fillWidthConstraint.animator().constant = trackWidth * fraction
        }
    }

    /// 索引结束：满格停留片刻再淡出（不含任何循环动画）
    func holdThenHide() {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard let self, !Task.isCancelled else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.35
                self.animator().alphaValue = 0
            }, completionHandler: nil)
            try? await Task.sleep(nanoseconds: 360_000_000)
            self.isHidden = true
        }
    }
}
