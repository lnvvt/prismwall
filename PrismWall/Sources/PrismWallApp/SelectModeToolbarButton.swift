import AppKit
import SwiftUI
import PrismWallCore

/// 工具栏「选择模式」按钮：进入后单击卡片即勾选，底部出现操作栏
struct SelectModeToolbarButton: NSViewRepresentable {
    let library: LibraryStore

    func makeCoordinator() -> Coordinator {
        Coordinator(library: library)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(
            image: Self.icon(active: false),
            target: context.coordinator,
            action: #selector(Coordinator.toggle(_:))
        )
        button.bezelStyle = .texturedRounded
        button.setButtonType(.momentaryPushIn)
        button.toolTip = "选择模式：单击卡片勾选，Esc 或「完成」退出"
        context.coordinator.button = button
        context.coordinator.refresh(button)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.button = button
        context.coordinator.refresh(button)
    }

    static func icon(active: Bool) -> NSImage {
        let name = active ? "checkmark.circle.fill" : "checkmark.circle"
        return NSImage(systemSymbolName: name, accessibilityDescription: "选择模式")
            ?? NSImage()
    }

    @MainActor
    final class Coordinator: NSObject {
        let library: LibraryStore
        weak var button: NSButton?

        init(library: LibraryStore) {
            self.library = library
        }

        @objc func toggle(_ sender: NSButton) {
            library.selectMode.toggle()
            refresh(sender)
        }

        /// 进入选择模式时高亮（强调色模板 + 实心图标）
        func refresh(_ button: NSButton) {
            let active = library.selectMode
            button.image = SelectModeToolbarButton.icon(active: active)
            button.contentTintColor = active ? .controlAccentColor : nil
        }
    }
}
