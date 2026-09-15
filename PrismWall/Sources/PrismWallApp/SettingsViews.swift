import SwiftUI
import PrismWallCore

// MARK: - 设置窗根视图（侧栏分类式）

struct SettingsRootView: View {
    enum Pane: String, CaseIterable, Identifiable {
        case general, library, shortcuts, security, about
        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: "通用"
            case .library: "媒体库"
            case .shortcuts: "快捷键"
            case .security: "隐私与安全"
            case .about: "关于"
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .library: "photo.stack"
            case .shortcuts: "keyboard"
            case .security: "lock.shield"
            case .about: "info.circle"
            }
        }
    }

    let library: LibraryStore
    let lock: AppLockManager
    @State private var pane: Pane = .general

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("设置")
                    .font(.title3.weight(.semibold))
                    .padding(.bottom, 14)
                ForEach(Pane.allCases) { p in
                    Button {
                        pane = p
                    } label: {
                        Label(p.title, systemImage: p.symbol)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 5)
                            .padding(.horizontal, 8)
                            .background(
                                pane == p
                                    ? Color.accentColor.opacity(0.22)
                                    : Color.clear,
                                in: RoundedRectangle(cornerRadius: 6)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(14)
            .frame(width: 168)

            Divider()

            ScrollView {
                Group {
                    switch pane {
                    case .general: GeneralPane(library: library)
                    case .library: LibrarySettingsPane(library: library)
                    case .shortcuts: ShortcutsPane()
                    case .security: SecurityPane(library: library, lock: lock)
                    case .about: AboutPane()
                    }
                }
                .padding(22)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(width: 700, height: 520)
    }
}

// MARK: - 通用

struct GeneralPane: View {
    let library: LibraryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            settingsSection("外观") {
                Picker(
                    "主题",
                    selection: Binding(
                        get: { library.appearanceMode },
                        set: { library.setAppearanceMode($0) }
                    )
                ) {
                    Text("跟随系统").tag(LibraryStore.AppearanceMode.system)
                    Text("浅色").tag(LibraryStore.AppearanceMode.light)
                    Text("深色").tag(LibraryStore.AppearanceMode.dark)
                }
                .pickerStyle(.segmented)
                .frame(width: 280)
            }
            settingsSection("查看器") {
                settingsRow(title: "快捷键徽章", subtitle: "查看器右上角显示 ? 按钮，点击查看快捷键") {
                    Toggle("", isOn: Binding(
                        get: { (library.viewState(forKey: "viewer.shortcutBadge") ?? "1") != "0" },
                        set: { library.setViewState($0 ? "1" : "0", forKey: "viewer.shortcutBadge") }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
            }

            settingsSection("浏览") {
                settingsRow(
                    title: "卡片密度",
                    subtitle: "⌘+ / ⌘- / ⌘0 或捏合随时调整，此处为默认起点"
                ) {
                    EmptyView()
                }
                Text("当前在墙视图用快捷键调整，此处保留默认值能力（后续版本提供滑杆）")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - 媒体库

struct LibrarySettingsPane: View {
    let library: LibraryStore
    @State private var reindexingSource: Int64?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            settingsSection("默认浏览方式") {
                settingsRow(title: "类型过滤", subtitle: "墙内显示的媒体类型") {
                    Picker("", selection: Binding(
                        get: { library.typeFilter },
                        set: { library.setTypeFilter($0) }
                    )) {
                        ForEach(MediaTypeFilter.allCases, id: \.self) { t in
                            Text(t.title).tag(t)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 120)
                }
                settingsRow(
                    title: "分组方式",
                    subtitle: "跟随视图 = 图库按时间 · 来源按文件夹（推荐）"
                ) {
                    Picker("", selection: Binding(
                        get: { library.groupingOverride },
                        set: { library.setGroupingOverride($0) }
                    )) {
                        Text("跟随视图").tag(LibraryGrouping?.none)
                        Text("按时间").tag(LibraryGrouping?.some(.byTime))
                        Text("按文件夹").tag(LibraryGrouping?.some(.byFolder))
                        Text("不分组").tag(LibraryGrouping?.some(.flat))
                    }
                    .labelsHidden()
                    .frame(width: 140)
                }
            }

            settingsSection("重新索引") {
                Text("强制重读文件元数据并重建缩略图。索引损坏或信息显示不正确时使用；磁盘上的文件不受影响。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if library.isScanning {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(library.progressText).font(.callout).foregroundStyle(.secondary)
                    }
                } else {
                    Button("重新索引全部来源") {
                        Task { await library.reindexAll() }
                    }
                    .disabled(library.sources.isEmpty)
                }
                ForEach(library.sources) { source in
                    HStack {
                        Label(sourceDisplayName(source.path), systemImage: "folder")
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("重新索引") {
                            reindexingSource = source.id
                            Task {
                                await library.reindexSource(source.id)
                                reindexingSource = nil
                            }
                        }
                        .controlSize(.small)
                        .disabled(library.isScanning)
                    }
                }
            }
        }
    }

    private func sourceDisplayName(_ path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }
}

// MARK: - 隐私与安全

struct SecurityPane: View {
    let library: LibraryStore
    let lock: AppLockManager

    @State private var showEnableSheet = false
    @State private var showDisableSheet = false
    @State private var showResetSheet = false
    @State private var clearDone = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            settingsSection("密码锁") {
                if lock.isEnabled {
                    settingsRow(
                        title: "密码锁已启用",
                        subtitle: "启动与本机解锁后需要输入密码；⌘L 可随时手动锁定"
                    ) {
                        Button("关闭…", role: .destructive) { showDisableSheet = true }
                            .controlSize(.small)
                    }
                    settingsRow(
                        title: "闲置自动锁定",
                        subtitle: "无操作达到设定时长后自动锁定"
                    ) {
                        Picker("", selection: Binding(
                            get: { lock.idleLimitSeconds },
                            set: { lock.idleLimitSeconds = $0 }
                        )) {
                            Text("从不").tag(0)
                            Text("1 分钟").tag(60)
                            Text("5 分钟").tag(300)
                            Text("15 分钟").tag(900)
                        }
                        .labelsHidden()
                        .frame(width: 120)
                    }
                } else {
                    settingsRow(
                        title: "密码锁未启用",
                        subtitle: "启动与闲置时需要密码解锁，防止他人查看你的媒体库"
                    ) {
                        Button("设置密码…") { showEnableSheet = true }
                    }
                }
            }

            settingsSection("缓存") {
                settingsRow(title: "缩略图缓存", subtitle: "清除后下次浏览时按需重新生成") {
                    if clearDone {
                        Text("已清除").font(.callout).foregroundStyle(.green)
                    } else {
                        Button("清除") {
                            library.clearThumbnailCache()
                            clearDone = true
                        }
                        .controlSize(.small)
                    }
                }
            }

            settingsSection("危险操作") {
                settingsRow(
                    title: "重置媒体库",
                    subtitle: "清除全部索引、来源与设置；磁盘上的照片视频文件不受影响"
                ) {
                    Button("重置…", role: .destructive) { showResetSheet = true }
                        .controlSize(.small)
                }
            }
        }
        .sheet(isPresented: $showEnableSheet) {
            EnableLockSheet(lock: lock)
        }
        .sheet(isPresented: $showDisableSheet) {
            DisableLockSheet(lock: lock)
        }
        .alert("重置媒体库？", isPresented: $showResetSheet) {
            Button("取消", role: .cancel) {}
            Button("重置", role: .destructive) {
                library.resetLibrary()
                lock.resetAll()
            }
        } message: {
            Text("将清除全部来源、索引与设置，磁盘上的照片视频文件不受影响。此操作也会同时关闭密码锁。")
        }
    }
}

struct EnableLockSheet: View {
    let lock: AppLockManager
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var confirm = ""
    @State private var error: String?

    var body: some View {
        VStack(spacing: 14) {
            Text("设置密码锁").font(.headline)
            SecureField("输入密码（至少 4 位）", text: $password)
                .textFieldStyle(.roundedBorder).frame(width: 240)
            SecureField("再次输入确认", text: $confirm)
                .textFieldStyle(.roundedBorder).frame(width: 240)
            if let error {
                Text(error).font(.callout).foregroundStyle(.red)
            }
            Text("忘记密码无法找回，只能通过「重置媒体库」清除密码（原始文件不受影响）。")
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: 300)
            HStack {
                Button("取消") { dismiss() }
                Button("启用") {
                    guard password.count >= 4 else {
                        error = "密码至少 4 位"; return
                    }
                    guard password == confirm else {
                        error = "两次输入不一致"; return
                    }
                    lock.enable(password: password)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(password.isEmpty || confirm.isEmpty)
            }
        }
        .padding(24)
    }
}

struct DisableLockSheet: View {
    let lock: AppLockManager
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var error = false

    var body: some View {
        VStack(spacing: 14) {
            Text("关闭密码锁").font(.headline)
            SecureField("输入当前密码", text: $password)
                .textFieldStyle(.roundedBorder).frame(width: 240)
                .onSubmit(disableNow)
            if error {
                Text("密码错误").font(.callout).foregroundStyle(.red)
            }
            HStack {
                Button("取消") { dismiss() }
                Button("关闭密码锁") { disableNow() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
    }

    private func disableNow() {
        if lock.disable(currentPassword: password) {
            dismiss()
        } else {
            error = true
        }
    }
}

// MARK: - 关于

struct AboutPane: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // 应用标识
            VStack(alignment: .leading, spacing: 4) {
                Text("PrismWall").font(.title2.weight(.semibold))
                Text("完全本地运行的 macOS 照片视频管理软件。零网络权限，所有数据仅存于本机。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 4)

            settingsSection("版本") {
                settingsRow(title: "软件版本", subtitle: "v\(appVersion)（正式版）") { EmptyView() }
                settingsRow(title: "系统要求", subtitle: "macOS 14.0 或更高版本，Apple Silicon") { EmptyView() }
                settingsRow(title: "开源协议", subtitle: "MIT License") {
                    Link("查看协议", destination: URL(string: "https://github.com/lnvvt/prismwall/blob/main/LICENSE")!)
                        .font(.callout)
                }
                settingsRow(title: "版权所有", subtitle: "© 2026 何文涛") { EmptyView() }
            }

            settingsSection("相关链接") {
                settingsRow(title: "源代码仓库", subtitle: "github.com/lnvvt/prismwall") {
                    Link("打开", destination: URL(string: "https://github.com/lnvvt/prismwall")!)
                        .font(.callout)
                }
                settingsRow(title: "问题反馈", subtitle: "提交前请先脱敏（勿附个人路径与照片）") {
                    Link("打开", destination: URL(string: "https://github.com/lnvvt/prismwall/issues")!)
                        .font(.callout)
                }
                settingsRow(title: "下载最新版本", subtitle: "Releases") {
                    Link("打开", destination: URL(string: "https://github.com/lnvvt/prismwall/releases/latest")!)
                        .font(.callout)
                }
            }
        }
    }
}

// MARK: - 公共组件

/// 统一设置行：左标题+副标题，右侧控件
@ViewBuilder
func settingsRow<Control: View>(
    title: String, subtitle: String,
    @ViewBuilder control: () -> Control
) -> some View {
    HStack {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.callout)
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        control()
    }
    .padding(.vertical, 4)
}

@ViewBuilder
func settingsSection<Content: View>(
    _ title: String, @ViewBuilder content: () -> Content
) -> some View {
    VStack(alignment: .leading, spacing: 10) {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
        content()
    }
}

// MARK: - 快捷键（查看 + 点击录键改组合 + 冲突拦截 + 恢复默认）

private let appVersion = (Bundle.main.object(
    forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.0.0"

struct ShortcutsPane: View {
    /// ShortcutManager.Action 的 scope 顺序即设置页分组顺序
    private let scopes = ["媒体墙", "播放器 · 舞台", "播放器", "舞台"]

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            ForEach(scopes, id: \.self) { scope in
                settingsSection(scope) {
                    VStack(spacing: 0) {
                        let actions = ShortcutManager.Action.allCases
                            .filter { $0.scope == scope }
                        ForEach(Array(actions.enumerated()), id: \.element.rawValue) { index, action in
                            HStack {
                                Text(action.label)
                                Spacer()
                                ComboRecorderButton(action: action)
                            }
                            .padding(.vertical, 7)
                            if index < actions.count - 1 { Divider() }
                        }
                    }
                }
            }

            HStack {
                Text("固定键：Esc 返回 · Enter 打开/进舞台 · Tab 与 1-9 舞台焦点 · 方向键浏览/快进/音量 · ⌘O 添加文件夹 · ⌘L 锁定")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("恢复默认") {
                    ShortcutManager.shared.resetAll()
                }
            }
        }
    }
}

/// 单个快捷键的展示/录键按钮：点击进入录制态，按下新组合即时校验
struct ComboRecorderButton: NSViewRepresentable {
    let action: ShortcutManager.Action

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: Self.title(for: action), target: context.coordinator,
                              action: #selector(Coordinator.clicked(_:)))
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.keyEquivalentModifierMask = []
        context.coordinator.button = button
        context.coordinator.startObserving()
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.button = button
    }

    static func dismantleNSView(_ button: NSButton, coordinator: Coordinator) {
        coordinator.stopObserving()
    }

    static func title(for action: ShortcutManager.Action) -> String {
        ShortcutManager.shared.displayString(for: action)
    }

    @MainActor
    final class Coordinator: NSObject {
        let action: ShortcutManager.Action
        weak var button: NSButton?
        private var recorder: Any?
        private var observer: NSObjectProtocol?
        private var revertTask: Task<Void, Never>?

        init(action: ShortcutManager.Action) {
            self.action = action
        }

        func startObserving() {
            observer = NotificationCenter.default.addObserver(
                forName: ShortcutManager.changedNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.recorder == nil else { return }
                    self.button?.title = ComboRecorderButton.title(for: self.action)
                }
            }
        }

        func stopObserving() {
            if let recorder { NSEvent.removeMonitor(recorder) }
            recorder = nil
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
        }

        @objc func clicked(_ sender: NSButton) {
            guard recorder == nil else { return }
            sender.title = "按下新组合…（Esc 取消）"
            sender.contentTintColor = .controlAccentColor
            recorder = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
                [weak self] event in
                MainActor.assumeIsolated {
                    self?.handleRecord(event)
                }
                return nil // 录制态吞掉所有按键
            }
        }

        private func handleRecord(_ event: NSEvent) {
            // 纯修饰键按下：等待完整组合
            let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
            guard !modifierKeyCodes.contains(event.keyCode) else { return }

            if event.keyCode == 53 { // Esc：取消录制（不占用 Esc 组合）
                finishRecording()
                return
            }

            let flags = event.modifierFlags.intersection(
                [.command, .option, .shift, .control]
            )
            let symbol: String
            switch event.keyCode {
            case 49: symbol = "空格"
            case 36: symbol = "↩"
            default:
                symbol = event.charactersIgnoringModifiers?.uppercased()
                    ?? "Key(\(event.keyCode))"
            }
            let combo = ShortcutManager.Combo(
                keyCode: event.keyCode,
                modifiers: Int(flags.rawValue),
                symbol: symbol
            )

            switch ShortcutManager.shared.check(action: action, combo: combo) {
            case .ok:
                ShortcutManager.shared.set(action: action, combo: combo)
                finishRecording()
            case .reserved:
                flashConflict("这是固定键，不可使用")
            case .conflict(let other):
                flashConflict("与「\(other.label)」冲突")
            }
        }

        /// 冲突提示：标题临时显示原因后恢复
        private func flashConflict(_ text: String) {
            button?.title = text
            button?.contentTintColor = .systemRed
            revertTask?.cancel()
            revertTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_600_000_000)
                guard let self, !Task.isCancelled else { return }
                self.finishRecording()
            }
        }

        private func finishRecording() {
            if let recorder { NSEvent.removeMonitor(recorder) }
            recorder = nil
            revertTask?.cancel()
            revertTask = nil
            button?.contentTintColor = nil
            button?.title = ComboRecorderButton.title(for: action)
        }
    }
}
