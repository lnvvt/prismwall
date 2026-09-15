import AppKit
import SwiftUI
import PrismWallCore

/// 工具栏「类型过滤」下拉按钮：全部/照片/视频，图标随当前状态变化
struct TypeFilterToolbarButton: NSViewRepresentable {
    let library: LibraryStore

    func makeCoordinator() -> Coordinator {
        Coordinator(library: library)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(
            image: Self.icon(library.typeFilter),
            target: context.coordinator,
            action: #selector(Coordinator.showMenu(_:))
        )
        button.bezelStyle = .texturedRounded
        button.setButtonType(.momentaryPushIn)
        button.toolTip = "类型过滤（V 循环切换）"
        context.coordinator.button = button
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        button.image = Self.icon(library.typeFilter)
        context.coordinator.button = button
    }

    static func icon(_ type: MediaTypeFilter) -> NSImage {
        NSImage(systemSymbolName: type.symbolName, accessibilityDescription: "类型过滤")
            ?? NSImage()
    }

    @MainActor
    final class Coordinator: NSObject {
        let library: LibraryStore
        weak var button: NSButton?

        init(library: LibraryStore) {
            self.library = library
        }

        @objc func showMenu(_ sender: NSButton) {
            let menu = NSMenu()
            for type in MediaTypeFilter.allCases {
                let item = NSMenuItem(
                    title: type.title,
                    action: #selector(choose(_:)),
                    keyEquivalent: ""
                )
                item.image = NSImage(
                    systemSymbolName: type.symbolName, accessibilityDescription: type.title
                )
                item.state = library.typeFilter == type ? .on : .off
                item.representedObject = type.rawValue
                item.target = self
                menu.addItem(item)
            }
            menu.popUp(
                positioning: nil,
                at: NSPoint(x: 0, y: sender.bounds.maxY + 3),
                in: sender
            )
        }

        @objc func choose(_ sender: NSMenuItem) {
            guard let raw = sender.representedObject as? String,
                  let type = MediaTypeFilter(rawValue: raw)
            else { return }
            library.setTypeFilter(type)
        }
    }
}
