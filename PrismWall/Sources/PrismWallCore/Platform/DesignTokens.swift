import AppKit

/// 视觉 token（苹果系）：语义化系统色 + 连续圆角 + Photos 式间距
enum DesignTokens {
    static let gridSpacing: CGFloat = 8
    static let cardCornerRadius: CGFloat = 8
    /// 卡片宽高比（1.49 ≈ 3:2），宽度按窗口列数动态计算、精确铺满
    static let cardAspect: CGFloat = 280.0 / 188.0
    static let defaultMinCardWidth: CGFloat = 210
    static let densityFloor: CGFloat = 150
    static let densityCeiling: CGFloat = 420
    static let densityStep: CGFloat = 30
    static let maxCardWidth: CGFloat = 460
    static let headerHeight: CGFloat = 52
    static let gridMargins = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)

    enum Color {
        static let textPrimary = NSColor.labelColor
        static let textSecondary = NSColor.secondaryLabelColor
        static let textFaint = NSColor.tertiaryLabelColor
        static let accent = NSColor.controlAccentColor
        /// 动态色：深色下发丝白线，浅色下低透明黑线（draw 时自动解析）
        static let cardBorder = NSColor(name: nil) { appearance in
            isDark(appearance)
                ? NSColor.white.withAlphaComponent(0.07)
                : NSColor.black.withAlphaComponent(0.12)
        }

        static func isDark(_ appearance: NSAppearance) -> Bool {
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        }

        @MainActor
        static func isDarkAppearance() -> Bool {
            isDark(NSApp.effectiveAppearance)
        }

        /// 气泡背景（深色黑胶囊 / 浅色白胶囊）；layer 赋值需在外观变化时重设
        @MainActor
        static func toastBackground() -> NSColor {
            isDarkAppearance()
                ? NSColor.black.withAlphaComponent(0.7)
                : NSColor.white.withAlphaComponent(0.9)
        }
    }
}
