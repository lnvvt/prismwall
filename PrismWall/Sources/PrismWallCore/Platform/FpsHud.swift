#if DEBUG
import AppKit

/// 右上角性能 HUD：滚动帧率 / 可视条目 / 总条目
@MainActor
final class FpsHud: NSView {
    private let label = NSTextField(labelWithString: "FPS —")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        label.textColor = NSColor.white.withAlphaComponent(0.9)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var displayText: String { label.stringValue }

    func update(scrollFPS: Int, visibleItems: Int, totalItems: Int) {
        label.stringValue = "FPS \(scrollFPS) · 可视 \(visibleItems) · 共 \(totalItems)"
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 9, yRadius: 9).fill()
    }
}

#endif
