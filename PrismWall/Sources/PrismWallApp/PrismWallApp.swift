import SwiftUI
import PrismWallCore

@main
struct PrismWallApp: App {
    private let isStageMode: Bool
    private let isSandboxSpikeMode: Bool
    private let addSourcePaths: [String]
    @State private var library = LibraryStore()
    /// 待确认移除的来源（弹确认框用）
    @State private var pendingRemovalSource: SourceRecord?
    @State private var lockManager = AppLockManager.shared
    @State private var idleMonitor: Any?
    @State private var idleTimer: Timer?

    init() {
        // 布局期 NSException 默认不落日志，挂处理器把原因写进 stderr
        NSSetUncaughtExceptionHandler { exception in
            NSLog("[PrismWall] UNCAUGHT %@: %@\n%@",
                  exception.name.rawValue,
                  exception.reason ?? "nil",
                  exception.callStackSymbols.prefix(20).joined(separator: "\n"))
        }
        let args = CommandLine.arguments
        #if DEBUG
        // CLI 模式：生成 S2 测试视频后直接退出（目录必须显式指定，
        // 默认路径会嵌入发布二进制——隐私自检会拦截测试数据路径）
        if let genIndex = args.firstIndex(of: "--videogen") {
            guard args.count > genIndex + 2 else {
                NSLog("[videogen] 用法: --videogen <数量> <输出目录>")
                exit(1)
            }
            Videogen.main(
                count: Int(args[genIndex + 1]) ?? 4, directory: args[genIndex + 2]
            ) // 内部 exit(0)
        }
        // CLI 模式：生成性能基准金丝雀数据集后直接退出
        if let canaryIndex = args.firstIndex(of: "--canary") {
            guard args.count > canaryIndex + 2 else {
                NSLog("[canary] 用法: --canary <数量> <输出目录>")
                exit(1)
            }
            CanaryGenerator.main(
                count: Int(args[canaryIndex + 1]) ?? 1000, directory: args[canaryIndex + 2]
            ) // 内部 exit(0)
        }
        #endif
        isStageMode = args.contains("--stage")
        isSandboxSpikeMode = args.contains("--sandbox-spike")
        var paths: [String] = []
        var index = 0
        while index < args.count - 1 {
            if args[index] == "--add-source" {
                paths.append(args[index + 1])
            }
            index += 1
        }
        addSourcePaths = paths

        // 无 bundle 从命令行启动时保证成为常规前台应用
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.activate(ignoringOtherApps: true)
        // 启动即应用持久化的外观偏好（跟随系统/浅色/深色）
        app.appearance = library.appearanceMode.nsAppearance
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if isSandboxSpikeMode {
                SandboxSpikeView()
                    .onAppear {
                        let app = NSApplication.shared
                        app.setActivationPolicy(.regular)
                        app.activate(ignoringOtherApps: true)
                    }
            } else if isStageMode {
                StageSpikeView()
                    .onAppear {
                        let app = NSApplication.shared
                        app.setActivationPolicy(.regular)
                        app.activate(ignoringOtherApps: true)
                    }
            } else {
                mainView
            }
            #else
            mainView
            #endif
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("添加文件夹…") {
                    library.addFolder()
                }
                .keyboardShortcut("o")
            }
            CommandGroup(after: .sidebar) {
                Picker(
                    "外观",
                    selection: Binding(
                        get: { library.appearanceMode },
                        set: { library.setAppearanceMode($0) }
                    )
                ) {
                    Text("跟随系统").tag(LibraryStore.AppearanceMode.system)
                    Text("浅色").tag(LibraryStore.AppearanceMode.light)
                    Text("深色").tag(LibraryStore.AppearanceMode.dark)
                }
                .pickerStyle(.inline)

                Divider()

                Picker(
                    "类型过滤",
                    selection: Binding(
                        get: { library.typeFilter },
                        set: { library.setTypeFilter($0) }
                    )
                ) {
                    Text("全部").tag(MediaTypeFilter.all)
                    Text("只看照片").tag(MediaTypeFilter.photo)
                    Text("只看视频").tag(MediaTypeFilter.video)
                }
                .pickerStyle(.inline)

                Button("选择模式") {
                    library.selectMode.toggle()
                }

                Picker(
                    "分组",
                    selection: Binding(
                        get: { library.effectiveGrouping },
                        set: { library.setGrouping($0) }
                    )
                ) {
                    Text("按时间").tag(LibraryGrouping.byTime)
                    Text("按文件夹").tag(LibraryGrouping.byFolder)
                    Text("不分组").tag(LibraryGrouping.flat)
                }
                .pickerStyle(.inline)

                Button("分组跟随视图") {
                    library.resetGrouping()
                }

                Divider()

                Button("锁定 PrismWall") {
                    lockManager.lock()
                }
                .keyboardShortcut("l", modifiers: .command)
                .disabled(!lockManager.isEnabled)
            }
        }

        Settings {
            SettingsRootView(library: library, lock: lockManager)
        }
    }

    @ViewBuilder
    private var mainView: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            LibraryWallScreen(library: library)
                .navigationTitle("PrismWall")
                .navigationSubtitle(subtitle)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        TypeFilterToolbarButton(library: library)
                    }
                    ToolbarItem(placement: .primaryAction) {
                        SelectModeToolbarButton(library: library)
                    }
                    ToolbarItem(placement: .primaryAction) {
                        SettingsLink {
                            Label("设置", systemImage: "gearshape")
                        }
                    }
                }
        }
        .frame(minWidth: 1100, minHeight: 680)
        // 密码锁覆盖层：锁定时盖住全部内容
        .overlay {
            if lockManager.isLocked {
                LockOverlayView(
                    manager: lockManager,
                    onReset: {
                        library.resetLibrary()
                        lockManager.resetAll()
                    }
                )
                .transition(.opacity)
            }
        }
        // 移除来源确认：明确告知磁盘文件不受影响
        .alert(
            "移除文件夹「\(sourceDisplayName(pendingRemovalSource?.path ?? ""))」？",
            isPresented: Binding(
                get: { pendingRemovalSource != nil },
                set: { if !$0 { pendingRemovalSource = nil } }
            )
        ) {
            Button("移除", role: .destructive) {
                if let source = pendingRemovalSource {
                    library.removeSource(source.id)
                }
                pendingRemovalSource = nil
            }
            Button("取消", role: .cancel) {
                pendingRemovalSource = nil
            }
        } message: {
            Text("只从媒体库移除该文件夹（\(pendingRemovalSource.map { "\(library.sourceCounts[$0.id] ?? 0)" } ?? "0") 项），不影响其他文件夹；磁盘上的文件不会被修改或删除。")
        }
        // S-8：启动时库损坏被隔离重建的一次性提示
        .alert(
            "媒体库已隔离重建",
            isPresented: Binding(
                get: { library.databaseQuarantined != nil },
                set: { if !$0 { library.clearDatabaseNotice() } }
            )
        ) {
            Button("好", role: .cancel) { library.clearDatabaseNotice() }
        } message: {
            Text(library.databaseQuarantined ?? "")
        }
        // 外观唯一由 NSApp.appearance 驱动（不叠加 preferredColorScheme：
        // 两套机制并存时，强制态→跟随系统的切换会残留窗口级覆盖造成明暗撕裂）
        .onAppear {
            library.start()
            // 启用密码锁则启动即锁定
            if lockManager.isEnabled {
                lockManager.lock()
            }
            // 闲置自动锁定：监听本机活动 + 定时检查
            idleMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.keyDown, .mouseMoved, .leftMouseDown, .scrollWheel]
            ) { [lockManager] event in
                lockManager.touch()
                return event
            }
            idleTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
                Task { @MainActor in AppLockManager.shared.checkIdle() }
            }
            for path in addSourcePaths {
                Task { await library.addSource(at: URL(fileURLWithPath: path)) }
            }
        }
    }

    private var subtitle: String {
        if library.isScanning {
            return library.progressText
        }
        return "共 \(library.totalCount) 项"
    }

    /// 侧栏单选：图库 / 收藏 / 各来源 互斥，整行热区，点哪切哪
    private var sidebar: some View {
        List(selection: Binding(
            get: { Optional(library.filter) },
            set: { newValue in
                if let filter = newValue {
                    library.setFilter(filter)
                }
            }
        )) {
            Section("资料库") {
                sidebarRow(.all, title: "图库", systemImage: "photo.on.rectangle.angled",
                           count: library.galleryCount)
                sidebarRow(.favorites, title: "收藏", systemImage: "heart",
                           count: library.favoriteCount)
            }
            Section("来源") {
                if library.sources.isEmpty {
                    Text("暂无来源")
                        .foregroundStyle(.secondary)
                }
                ForEach(library.sources) { source in
                    sidebarRow(
                        .source(source.id),
                        title: (source.state == "offline" ? "⚠️ " : "")
                            + sourceDisplayName(source.path),
                        systemImage: "folder",
                        count: library.sourceCounts[source.id] ?? 0
                    )
                    .contextMenu {
                        Button("在访达中显示") {
                            NSWorkspace.shared.activateFileViewerSelecting(
                                [URL(fileURLWithPath: source.path)]
                            )
                        }
                        Button("拷贝文件夹路径") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(
                                source.path, forType: .string
                            )
                        }
                        Divider()
                        Button("移除此文件夹…", role: .destructive) {
                            pendingRemovalSource = source
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button {
                    library.addFolder()
                } label: {
                    Label("添加文件夹", systemImage: "plus.circle")
                }
                .buttonStyle(.borderless)
                Spacer()
                if library.isScanning {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(10)
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 220)
    }

    private func sidebarRow(
        _ filter: LibraryStore.LibraryFilter, title: String, systemImage: String, count: Int
    ) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text("\(count)")
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .font(.callout)
        }
        .tag(filter) // List(selection:) 依靠 tag 识别行，缺失则点击不生效
    }

    /// 显示名：保留真实名称（含隐藏文件夹的点前缀）——
    /// 之前去掉点显示导致用户在 Finder 里按显示名找不到文件夹
    private func sourceDisplayName(_ path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }
}

/// 设置窗口（⌘, 或工具栏齿轮）：外观与将来的个性化选项都放在这里

/// 工具栏「类型 + 分组」下拉按钮：一组 NSPopUpButton，风格与外观按钮一致
/// （约束：墙的全部组合只增加这一个工具栏控件，墙内零新增 UI）

extension LibraryStore.AppearanceMode {
    /// 参考样式：系统 / 深色 / 浅色（配显示器、月亮、太阳图标）
    static let displayOrder: [LibraryStore.AppearanceMode] = [.system, .dark, .light]

    var title: String {
        switch self {
        case .system: "系统"
        case .dark: "深色"
        case .light: "浅色"
        }
    }

    var symbolName: String {
        switch self {
        case .system: "display"
        case .dark: "moon"
        case .light: "sun.max"
        }
    }
}

/// 工具栏外观下拉按钮：SF Symbol 图标 + 对勾，随当前模式切换按钮图标
