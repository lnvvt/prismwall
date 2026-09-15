import AppKit

/// 选择模式底部浮动操作栏：已选计数 + 六动作（收藏/舞台/访达/拷贝路径/共享/完成）
/// 与密度提示气泡同款浮层模式：毛玻璃胶囊、隐藏时 alpha 0 + isHidden
@MainActor
final class SelectionBarView: NSVisualEffectView {
    enum Action: Int {
        case toggleFavorite, stage, finder, copyPath, share, done
    }

    /// 动作触发（第二个参数为按钮自身，共享面板需要锚点视图）
    var onAction: ((Action, NSView) -> Void)?

    private let countLabel = NSTextField(labelWithString: "已选择 0 项")
    private var buttons: [Action: NSButton] = [:]

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
        translatesAutoresizingMaskIntoConstraints = false
        alphaValue = 0
        isHidden = true

        countLabel.font = .systemFont(ofSize: 13, weight: .medium)
        countLabel.textColor = .labelColor

        let stack = NSStackView(views: [countLabel])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false

        for action in [Action.toggleFavorite, .stage, .finder, .copyPath, .share, .done] {
            let button = NSButton(image: Self.icon(action), target: self,
                                  action: #selector(actionFired(_:)))
            button.bezelStyle = .shadowlessSquare
            button.isBordered = false
            button.toolTip = Self.tooltip(action)
            buttons[action] = button
            stack.addArrangedSubview(button)
            if action != .done {
                let divider = NSView()
                divider.wantsLayer = true
                divider.layer?.backgroundColor = NSColor.separatorColor.cgColor
                divider.translatesAutoresizingMaskIntoConstraints = false
                divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
                divider.heightAnchor.constraint(equalToConstant: 16).isActive = true
                stack.addArrangedSubview(divider)
            }
        }

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        // NSVisualEffectView 需要 layer 圆角在布局后兜底（hudWindow 材质圆角随窗口）
    }

    /// 显隐 + 计数一体更新；count 变化时同步按钮可用态
    func apply(visible: Bool, count: Int) {
        updateCount(count)
        guard isHidden == visible else { return }
        isHidden = !visible
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            animator().alphaValue = visible ? 1 : 0
        }
    }

    func updateCount(_ count: Int) {
        countLabel.stringValue = count == 0 ? "未选择项目" : "已选择 \(count) 项"
        buttons[.toggleFavorite]?.isEnabled = count > 0
        buttons[.finder]?.isEnabled = count > 0
        buttons[.copyPath]?.isEnabled = count > 0
        buttons[.share]?.isEnabled = count > 0
        buttons[.stage]?.isEnabled = count >= 2
    }

    @objc private func actionFired(_ sender: NSButton) {
        guard let action = buttons.first(where: { $0.value === sender })?.key else { return }
        onAction?(action, sender)
    }

    private static func icon(_ action: Action) -> NSImage {
        let name: String
        switch action {
        case .toggleFavorite: name = "heart"
        case .stage: name = "square.grid.2x2"
        case .finder: name = "folder"
        case .copyPath: name = "doc.on.doc"
        case .share: name = "square.and.arrow.up"
        case .done: name = "checkmark"
        }
        let image = NSImage(systemSymbolName: name,
                            accessibilityDescription: tooltip(action)) ?? NSImage()
        return image
    }

    private static func tooltip(_ action: Action) -> String {
        switch action {
        case .toggleFavorite: return "收藏 / 取消收藏"
        case .stage: return "进入多视频舞台（≥2 项）"
        case .finder: return "在访达中显示"
        case .copyPath: return "拷贝文件路径"
        case .share: return "共享…"
        case .done: return "完成（退出选择模式）"
        }
    }
}
