#if DEBUG
import AppKit
import Observation
import SwiftUI

/// S4 Spike：沙盒内文件夹授权 → 安全书签 → 扫描计数 → 文件监听延迟实测
/// 对照三种监听机制：FSEvents(granted) / FSEvents(容器 tmp) / vnode kevent(granted)
@MainActor
@Observable
public final class SandboxSpikeController {
    private(set) var statusLines: [String] = []
    private(set) var mediaCount = 0
    private(set) var eventCount = 0
    private(set) var lastEvent = "（尚无事件）"

    private var grantedURL: URL?
    private var streams: [String: FSEventStreamRef] = [:]
    private var boxes: [EventBox] = []
    private var vnodeSource: DispatchSourceFileSystemObject?
    private var pendingWrites: [String: CFAbsoluteTime] = [:]
    private var vnodeWatchedPath = ""

    private let bookmarkFile: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PrismWall", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("source.bookmark")
    }()

    public init() {
        statusLines.append("home=\(NSHomeDirectory())")
    }

    public func start() {
        restoreOrPrompt()
    }

    /// 启动时优先恢复书签（验证重启不再弹窗），失败才弹面板
    private func restoreOrPrompt() {
        guard let data = try? Data(contentsOf: bookmarkFile) else {
            log("无已存书签，弹出授权面板")
            pickFolder()
            return
        }
        var isStale = false
        if let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) {
            log("书签恢复成功 stale=\(isStale) \(url.lastPathComponent)")
            grant(url, saveBookmark: isStale)
            return
        }
        log("书签恢复失败，需要重新授权")
        pickFolder()
    }

    public func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "选择一个包含照片/视频的文件夹（用于沙盒授权与文件监听测试）"
        guard panel.runModal() == .OK, let url = panel.url else {
            log("未选择文件夹")
            return
        }
        grant(url, saveBookmark: true)
    }

    private func grant(_ url: URL, saveBookmark: Bool) {
        grantedURL = url
        if saveBookmark {
            do {
                let data = try url.bookmarkData(
                    options: .withSecurityScope, includingResourceValuesForKeys: nil
                )
                try data.write(to: bookmarkFile)
                log("安全书签已保存")
            } catch {
                log("书签创建失败: \(error.localizedDescription)")
            }
        }
        let accessing = url.startAccessingSecurityScopedResource()
        log("startAccessing=\(accessing) \(url.path)")
        scan()
        watchAll()
    }

    private func scan() {
        guard let url = grantedURL else { return }
        let mediaExtensions: Set<String> = [
            "jpg", "jpeg", "png", "heic", "webp", "gif", "tif", "tiff",
            "mp4", "mov", "m4v",
        ]
        var count = 0
        if let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: nil
        ) {
            for case let file as URL in enumerator {
                if mediaExtensions.contains(file.pathExtension.lowercased()) {
                    count += 1
                }
            }
        }
        mediaCount = count
        log("扫描完成：\(count) 个媒体文件")
    }

    private func watchAll() {
        guard let url = grantedURL, streams.isEmpty else { return }
        watchPath(url.path, label: "granted")
        let tmpPath = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).path
        watchPath(tmpPath, label: "container-tmp")
        installVNodeWatcher(for: url)
        if !streams.isEmpty {
            selfWriteAfterDelay()
        }
    }

    private func watchPath(_ path: String, label: String) {
        let box = EventBox { [weak self] paths in
            MainActor.assumeIsolated { self?.handleEvents(paths, from: label) }
        }
        boxes.append(box)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passRetained(box).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            Self.fsCallback,
            &context,
            [path] as CFArray,
            FSEventStreamEventId.max, // kFSEventStreamSinceNow（C 宏不导入 Swift）
            0.0,
            UInt32(kFSEventStreamCreateFlagFileEvents)
        ) else {
            log("[\(label)] FSEventStreamCreate 失败")
            return
        }
        streams[label] = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        log("[\(label)] FSEventStreamStart=\(FSEventStreamStart(stream))")
    }

    /// vnode（kevent）方式：对目录 fd 监听 .write，沙盒内不经过 FSEvents 服务
    private func installVNodeWatcher(for url: URL) {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            log("vnode: open 目录 fd 失败")
            return
        }
        vnodeWatchedPath = url.path
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: .write, queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.log("vnode: 目录变更事件")
                self.checkPendingWrites(via: "vnode")
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        vnodeSource = source
        log("vnode 监听已启动")
    }

    /// 4 秒后向两个目录各写一个测试文件，测各机制的事件延迟（PRD F1：≤ 2s）
    private func selfWriteAfterDelay() {
        guard let url = grantedURL else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard let self else { return }
            let stamp = Int(Date().timeIntervalSince1970)
            for dir in [url.path, URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).path] {
                let path = (dir as NSString).appendingPathComponent("prismwall-test-\(stamp).jpg")
                do {
                    try Data("prismwall spike test".utf8).write(to: URL(fileURLWithPath: path))
                    self.pendingWrites[path] = CFAbsoluteTimeGetCurrent()
                    self.log("已写入测试文件 \(path)")
                } catch {
                    self.log("测试文件写入失败(\(dir)): \(error.localizedDescription)")
                }
            }
        }
    }

    private func handleEvents(_ paths: [String], from label: String) {
        eventCount += paths.count
        lastEvent = "[\(label)] " + paths.joined(separator: ", ")
        log("[\(label)] FSEvents 收到 \(paths.count) 个事件")
        checkPendingWrites(via: "fs-\(label)")
    }

    private func checkPendingWrites(via: String) {
        let now = CFAbsoluteTimeGetCurrent()
        for (path, t) in pendingWrites where now - t > 0.0001 {
            let latencyMs = (now - t) * 1000
            log(String(format: "%@ 事件延迟 %.0f ms（目标 ≤ 2000ms）→ %@", via, latencyMs, (path as NSString).lastPathComponent))
            try? FileManager.default.removeItem(atPath: path)
        }
        if via.hasPrefix("fs-") {
            pendingWrites.removeAll()
        } else {
            // vnode 不带路径，仅记录延迟，文件留给 FSEvents 分支清理
        }
        scan()
    }

    private func log(_ line: String) {
        statusLines.append(line)
        if statusLines.count > 40 {
            statusLines.removeFirst(statusLines.count - 40)
        }
        NSLog("[PrismWall][S4] %@", line)
    }

    nonisolated private static let fsCallback: FSEventStreamCallback = {
        _, clientInfo, _, eventPaths, _, _ in
        guard let clientInfo else { return }
        let box = Unmanaged<EventBox>.fromOpaque(clientInfo).takeUnretainedValue()
        let cfArray = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
        let paths = (cfArray as NSArray) as? [String] ?? []
        box.onEvents(paths)
    }
}

/// C 回调持有的事件处理器盒子
private final class EventBox {
    let onEvents: ([String]) -> Void
    init(onEvents: @escaping ([String]) -> Void) {
        self.onEvents = onEvents
    }
}

public struct SandboxSpikeView: View {
    @State private var controller = SandboxSpikeController()

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("S4 沙盒授权 + 文件监听 Spike")
                    .font(.headline)
                Spacer()
                Text("媒体 \(controller.mediaCount) · 事件 \(controller.eventCount)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Button("选择媒体文件夹…") { controller.pickFolder() }
            }
            Text("最后事件：\(controller.lastEvent)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            ScrollView {
                Text(controller.statusLines.joined(separator: "\n"))
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .frame(minWidth: 720, minHeight: 480)
        .onAppear { controller.start() }
    }
}

#endif
