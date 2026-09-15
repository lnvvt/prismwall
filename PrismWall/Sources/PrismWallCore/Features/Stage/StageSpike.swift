#if DEBUG
import AVFoundation
import Observation
import SwiftUI

/// S2 Spike 控制器：4 路 AVPlayer 同播 + 偏差测量
@MainActor
@Observable
public final class StageSpikeController {
    private(set) var players: [AVPlayer] = []
    private(set) var statusText = "等待视频就绪…"
    private(set) var driftLines: [String] = []
    private(set) var isPlaying = false

    private var keyMonitor: Any?
    private var monitorTask: Task<Void, Never>?

    public init() {}

    public func start(videoDirectory: String) {
        guard players.isEmpty else { return }
        let urls = (1...4).map {
            URL(fileURLWithPath: videoDirectory)
                .appendingPathComponent(String(format: "sample_%02d.mp4", $0))
        }
        players = urls.map { AVPlayer(url: $0) }
        for player in players {
            player.automaticallyWaitsToMinimizeStalling = false
            player.actionAtItemEnd = .none
        }

        installLoopObservers()
        installKeyMonitor()
        monitorTask = Task { [weak self] in
            await self?.waitReadyAndPlay()
            await self?.runDriftLoop()
        }
    }

    /// 全部就绪后在同一 runloop tick 齐发播放
    private func waitReadyAndPlay() async {
        let start = Date()
        while true {
            let allReady = players.allSatisfy { $0.currentItem?.status == .readyToPlay }
            if allReady || Date().timeIntervalSince(start) > 8 { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        for player in players { player.play() }
        isPlaying = true
        statusText = "已齐发播放（同一 tick）"
    }

    private func runDriftLoop() async {
        var logged = 0
        while !Task.isCancelled {
            let times = players.map { $0.currentTime().seconds }
            if !times.isEmpty, times.allSatisfy(\.isFinite) {
                let drift = (times.max() ?? 0) - (times.min() ?? 0)
                driftLines = times.enumerated().map {
                    String(format: "P%d %08.3f", $0.offset + 1, $0.element)
                }
                statusText = String(
                    format: "同步偏差 %.0f ms · %@", drift * 1000,
                    isPlaying ? "播放中（空格暂停）" : "已暂停（空格继续）"
                )
                if logged < 8, isPlaying {
                    NSLog(
                        "[PrismWall] drift=%.0fms times=%@", drift * 1000,
                        times.map { String(format: "%.3f", $0) }.joined(separator: ",")
                    )
                    logged += 1
                }
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    public func togglePlayPause() {
        if isPlaying {
            for player in players { player.pause() }
        } else {
            for player in players { player.play() }
        }
        isPlaying.toggle()
    }

    /// 播完自动回零循环，便于持续观测
    private func installLoopObservers() {
        for player in players {
            NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: player.currentItem,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isPlaying else { return }
                    player.seek(to: .zero)
                    player.play()
                }
            }
        }
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 49 { // 空格
                MainActor.assumeIsolated { self?.togglePlayPause() }
                return nil
            }
            return event
        }
    }

    // Spike 生命周期即 App 生命周期，不做 deinit 清理（deinit 为 nonisolated，无法触碰主隔离状态）
}

/// S2 Spike 视图：2×2 四路同播
public struct StageSpikeView: View {
    @State private var controller = StageSpikeController()

    public init() {}

    public var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("S2 多视频同播 Spike")
                    .font(.headline)
                Spacer()
                Text(controller.statusText)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 14) {
                ForEach(Array(controller.driftLines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            .frame(height: 16)

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 10),
                    GridItem(.flexible(), spacing: 10),
                ],
                spacing: 10
            ) {
                ForEach(controller.players.indices, id: \.self) { index in
                    PlayerLayerView(player: controller.players[index])
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .overlay(alignment: .topLeading) {
                            Text("P\(index + 1)")
                                .font(.caption.bold())
                                .padding(6)
                                .foregroundStyle(.white)
                                .background(.black.opacity(0.5))
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            Spacer(minLength: 0)
            Text("空格：全体播放 / 暂停 · 播完自动循环")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(Color.black)
        .onAppear { controller.start(videoDirectory: "/tmp/prismwall-media") }
    }
}

struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    final class LayerHostView: NSView {
        private let playerLayer = AVPlayerLayer()

        init(player: AVPlayer) {
            super.init(frame: .zero)
            wantsLayer = true
            playerLayer.player = player
            playerLayer.videoGravity = .resizeAspect
            playerLayer.backgroundColor = NSColor.black.cgColor
            layer?.addSublayer(playerLayer)
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

    func makeNSView(context: Context) -> NSView {
        LayerHostView(player: player)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

#endif
