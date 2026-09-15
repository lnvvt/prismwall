import SwiftUI

/// 主窗口的墙视图：AppKit 集合视图经 representable 桥接进 SwiftUI
public struct LibraryWallScreen: NSViewRepresentable {
    public typealias NSViewType = NSView

    let library: LibraryStore

    public init(library: LibraryStore) {
        self.library = library
    }

    public func makeNSView(context: Context) -> NSView {
        WallContainerView(library: library)
    }

    public func updateNSView(_ nsView: NSView, context: Context) {}
}
