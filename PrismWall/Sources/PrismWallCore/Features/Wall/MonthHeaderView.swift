import AppKit

@MainActor
final class MonthHeaderView: NSView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("MonthHeader")

    private let titleLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        titleLabel.font = .systemFont(ofSize: 26, weight: .semibold)
        titleLabel.textColor = DesignTokens.Color.textPrimary
        countLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        countLabel.textColor = DesignTokens.Color.textSecondary

        for label in [titleLabel, countLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 56),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            titleLabel.firstBaselineAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            countLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 12),
            countLabel.firstBaselineAnchor.constraint(equalTo: bottomAnchor, constant: -15),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(title: String, countText: String) {
        titleLabel.stringValue = title
        countLabel.stringValue = countText
    }
}
