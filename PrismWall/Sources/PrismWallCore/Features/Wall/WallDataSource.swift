import os
import AppKit

@MainActor
final class WallDataSource: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate,
    NSCollectionViewDelegateFlowLayout {
    /// 单一实例终身持有（运行期替换 dataSource 对象会与布局缓存竞争导致断言崩溃），只原地更新
    private(set) var sections: [WallSection]
    /// 卡片被点击时触发（经 ThumbCellItem 转发，携带内容与自身视图）
    var onOpen: ((WallItem, NSView) -> Void)?
    /// 收藏切换
    var onToggleFavorite: ((WallItem) -> Void)?
    /// 选择模式：单击切换勾选（携带目标 indexPath，容器程序化改 selection）
    var onToggleSelectAt: ((IndexPath) -> Void)?
    /// 选择集合变化（含程序化变更），参数为当前选中数
    var onSelectionChange: ((Int) -> Void)?

    init(sections: [WallSection]) {
        self.sections = sections
        super.init()
    }

    func update(sections: [WallSection]) {
        self.sections = sections
    }

    /// NSCollectionViewGridLayout 在 0 分区时会请求第 0 分区条目数并断言崩溃（AppKit 坑），
    /// 空库时保留一个占位分区兜底
    func numberOfSections(in collectionView: NSCollectionView) -> Int {
        max(1, sections.count)
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        numberOfItemsInSection section: Int
    ) -> Int {
        guard section < sections.count else { return 0 }
        return sections[section].items.count
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        let item = collectionView.makeItem(
            withIdentifier: ThumbCellItem.reuseIdentifier,
            for: indexPath
        )
        if let thumb = item as? ThumbCellItem {
            thumb.configure(sections[indexPath.section].items[indexPath.item])
            thumb.onOpen = { [weak self] media, view in
                self?.onOpen?(media, view)
            }
            thumb.onToggleFavorite = { [weak self] media in
                self?.onToggleFavorite?(media)
            }
            thumb.onToggleSelect = { [weak self, weak collectionView] in
                guard let self, let collectionView,
                      let ip = collectionView.indexPath(for: thumb) else { return }
                self.onToggleSelectAt?(ip)
            }
        }
        return item
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind,
        at indexPath: IndexPath
    ) -> NSView {
        let view = collectionView.makeSupplementaryView(
            ofKind: NSCollectionView.elementKindSectionHeader,
            withIdentifier: MonthHeaderView.reuseIdentifier,
            for: indexPath
        )
        if let header = view as? MonthHeaderView {
            guard indexPath.section < sections.count else {
                header.configure(title: "", countText: "")
                return view
            }
            let section = sections[indexPath.section]
            let videoCount = section.items.filter(\.isVideo).count
            header.configure(
                title: section.title,
                countText: "\(section.items.count) 项 · \(videoCount) 视频"
            )
        }
        return view
    }

    /// 诊断用：自带选中回调在该桥接下不可靠，记录事件供排查
    func collectionView(
        _ collectionView: NSCollectionView,
        didSelectItemsAt indexPaths: Set<IndexPath>
    ) {
        PWLog.wall.debug("didSelectItemsAt count=\(indexPaths.count)")
        onSelectionChange?(collectionView.selectionIndexPaths.count)
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        didDeselectItemsAt indexPaths: Set<IndexPath>
    ) {
        onSelectionChange?(collectionView.selectionIndexPaths.count)
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        layout collectionViewLayout: NSCollectionViewLayout,
        referenceSizeForHeaderInSection section: Int
    ) -> NSSize {
        NSSize(width: 0, height: DesignTokens.headerHeight)
    }
}
