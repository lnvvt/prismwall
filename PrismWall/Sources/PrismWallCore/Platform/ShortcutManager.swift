import AppKit

/// 应用内快捷键单一事实源：动作 → 组合键，全部可重映射动作的查询入口。
/// 持久化 UserDefaults（JSON）；设置页为唯一写入方，监听侧只读。
/// 固定键（录键时禁止占用）：Esc / Enter / Tab / 方向键 / 数字键 1-9 / ⌘O / ⌘L
@MainActor
public final class ShortcutManager {
    public static let shared = ShortcutManager()
    /// 组合变更通知（设置页按钮刷新显示）
    public static let changedNotification = Notification.Name("pwShortcutsChanged")

    public struct Combo: Equatable, Codable {
        public var keyCode: UInt16
        /// NSEvent.ModifierFlags.deviceIndependentFlagsMask 的 rawValue
        public var modifiers: Int
        /// 录键时捕获的按键符号（显示用）
        public var symbol: String

        public init(keyCode: UInt16, modifiers: Int, symbol: String) {
            self.keyCode = keyCode
            self.modifiers = modifiers
            self.symbol = symbol
        }
    }

    public enum Action: String, CaseIterable {
        case toggleFavorite   // 墙：F 收藏
        case cycleTypeFilter  // 墙：V 类型过滤循环
        case zoomIn           // 墙：⌘= 密度加列
        case zoomOut          // 墙：⌘- 密度减列
        case zoomReset        // 墙：⌘0 密度重置
        case playPause        // 播放器·舞台：空格
        case frameCapture     // 播放器：C 截帧
        case toggleMute       // 播放器·舞台：M 静音
        case rateUp           // 播放器·舞台：] 变速+
        case rateDown         // 播放器·舞台：[ 变速-
        case toggleLayout     // 舞台：G 布局
        case toggleSync       // 舞台：S 同步/独立

        public var label: String {
            switch self {
            case .toggleFavorite: return "收藏 / 取消收藏"
            case .cycleTypeFilter: return "类型过滤循环"
            case .zoomIn: return "放大卡片"
            case .zoomOut: return "缩小卡片"
            case .zoomReset: return "重置卡片大小"
            case .playPause: return "播放 / 暂停"
            case .frameCapture: return "视频截帧"
            case .toggleMute: return "静音切换"
            case .rateUp: return "播放加速"
            case .rateDown: return "播放减速"
            case .toggleLayout: return "舞台布局切换"
            case .toggleSync: return "同步 / 独立模式"
            }
        }

        /// 作用位置（设置页分组）
        public var scope: String {
            switch self {
            case .toggleFavorite, .cycleTypeFilter, .zoomIn, .zoomOut, .zoomReset:
                return "媒体墙"
            case .frameCapture, .rateUp, .rateDown:
                return "播放器"
            case .playPause, .toggleMute:
                return "播放器 · 舞台"
            case .toggleLayout, .toggleSync:
                return "舞台"
            }
        }

        public var defaultCombo: Combo {
            let none = 0
            switch self {
            case .toggleFavorite: return Combo(keyCode: 3, modifiers: none, symbol: "F")
            case .cycleTypeFilter: return Combo(keyCode: 9, modifiers: none, symbol: "V")
            case .zoomIn:
                return Combo(keyCode: 24, modifiers: Int(NSEvent.ModifierFlags.command.rawValue), symbol: "=")
            case .zoomOut:
                return Combo(keyCode: 27, modifiers: Int(NSEvent.ModifierFlags.command.rawValue), symbol: "-")
            case .zoomReset:
                return Combo(keyCode: 29, modifiers: Int(NSEvent.ModifierFlags.command.rawValue), symbol: "0")
            case .playPause: return Combo(keyCode: 49, modifiers: none, symbol: "空格")
            case .frameCapture: return Combo(keyCode: 8, modifiers: none, symbol: "C")
            case .toggleMute: return Combo(keyCode: 46, modifiers: none, symbol: "M")
            case .rateUp: return Combo(keyCode: 30, modifiers: none, symbol: "]")
            case .rateDown: return Combo(keyCode: 33, modifiers: none, symbol: "[")
            case .toggleLayout: return Combo(keyCode: 5, modifiers: none, symbol: "G")
            case .toggleSync: return Combo(keyCode: 1, modifiers: none, symbol: "S")
            }
        }
    }

    /// 设置冲突结果
    public enum SetResult {
        case ok
        case reserved           // 撞固定键
        case conflict(Action)   // 撞其他可改动作
    }

    private var combos: [Action: Combo] = [:]
    private let storageKey = "shortcuts.v1"

    private init() {
        combos = Action.allCases.reduce(into: [:]) { $0[$1] = $1.defaultCombo }
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode([String: Combo].self, from: data) {
            for action in Action.allCases {
                if var combo = saved[action.rawValue] {
                    // 兼容历史脏数据：修饰位只保留 ⌘⌥⇧⌃
                    combo.modifiers &= Int(NSEvent.ModifierFlags(
                        arrayLiteral: .command, .option, .shift, .control
                    ).rawValue)
                    combos[action] = combo
                }
            }
        }
    }

    /// 查询：事件是否命中动作。只比对 ⌘⌥⇧⌃ 四个真实修饰位
    /// （function/numericPad 等设备位会污染 rawValue）；⌥ 不参与匹配——
    /// 舞台 ⌥M=全部静音 等附加语义依赖它
    public func matches(_ action: Action, _ event: NSEvent) -> Bool {
        guard let combo = combos[action] else { return false }
        let flags = Self.userModifiers(of: event)
        return event.keyCode == combo.keyCode && Int(flags.rawValue) == combo.modifiers
    }

    /// 四个用户修饰键（⌘⌥⇧⌃），其余设备位一律剔除
    private static func userModifiers(of event: NSEvent) -> NSEvent.ModifierFlags {
        event.modifierFlags
            .intersection([.command, .option, .shift, .control])
    }

    public func combo(for action: Action) -> Combo { combos[action] ?? action.defaultCombo }

    public func displayString(for action: Action) -> String {
        Self.displayString(combo(for: action))
    }

    public static func displayString(_ combo: Combo) -> String {
        var flags = NSEvent.ModifierFlags(rawValue: UInt(combo.modifiers))
        _ = flags.remove(.option)
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        return text + combo.symbol
    }

    /// 录键校验：先 reserved 后 conflict，设置页据此提示
    public func check(action: Action, combo: Combo) -> SetResult {
        if Self.reservedCombos.contains(combo) { return .reserved }
        for (other, existing) in combos where other != action && existing == combo {
            return .conflict(other)
        }
        return .ok
    }

    public func set(action: Action, combo: Combo) {
        combos[action] = combo
        persist()
        NotificationCenter.default.post(name: Self.changedNotification, object: nil)
    }

    public func reset(action: Action) {
        set(action: action, combo: action.defaultCombo)
    }

    public func resetAll() {
        for action in Action.allCases { combos[action] = action.defaultCombo }
        persist()
        NotificationCenter.default.post(name: Self.changedNotification, object: nil)
    }

    private func persist() {
        let payload = combos.mapKeys(\.rawValue)
        if let data = try? JSONEncoder().encode(payload) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    /// 固定交互键（不参与重映射，录键时禁止占用）：Esc / Enter / Tab / 方向键 /
    /// 数字键 1-9 / ⌘O 添加文件夹 / ⌘L 锁定
    private static let reservedCombos: [Combo] = {
        let none = 0
        let cmd = Int(NSEvent.ModifierFlags.command.rawValue)
        let keyCodes: [UInt16] = [
            53, 36, 76, 48, 123, 124, 125, 126, // Esc Enter 小键盘回车 Tab ←→↓↑
            18, 19, 20, 21, 23, 22, 26, 28, 25, // 数字 1-9
        ]
        var combos = keyCodes.map { Combo(keyCode: $0, modifiers: none, symbol: "") }
        combos.append(Combo(keyCode: 31, modifiers: cmd, symbol: "O")) // ⌘O
        combos.append(Combo(keyCode: 37, modifiers: cmd, symbol: "L")) // ⌘L
        return combos
    }()
}

extension Dictionary {
    func mapKeys<Transformed>(_ transform: (Key) throws -> Transformed) rethrows
        -> [Transformed: Value] {
        var result: [Transformed: Value] = [:]
        for (key, value) in self {
            result[try transform(key)] = value
        }
        return result
    }
}
