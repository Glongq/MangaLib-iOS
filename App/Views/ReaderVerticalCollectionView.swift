import SwiftUI
import UIKit

/// A continuous native reader list with hosted SwiftUI images and chapter footers.
enum ReaderVerticalItem: Hashable {
    case page(chapterIndex: Int, pageIndex: Int, page: PageItem)
    case footer(chapterIndex: Int)
}

struct ReaderVerticalCollectionView<Content: View>: UIViewRepresentable {
    let items: [ReaderVerticalItem]
    let gap: CGFloat
    let scale: CGFloat
    let inertiaMultiplier: Double
    let appearanceRevision: Int
    let onVisiblePage: (Int, Int) -> Void
    let onFooter: (Int) -> Void
    let onPrefetch: ([(Int, Int)]) -> Void
    let content: (ReaderVerticalItem, CGFloat, @escaping (CGSize) -> Void) -> Content

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UICollectionView {
        let layout = ReaderVerticalLayout()
        layout.sizeForItem = { [weak coordinator = context.coordinator] index, width in
            coordinator?.sizeForItem(at: index, width: width) ?? .zero
        }
        let collection = VerticalReaderCollectionView(frame: .zero, collectionViewLayout: layout)
        collection.backgroundColor = .clear
        collection.contentInsetAdjustmentBehavior = .never
        collection.showsVerticalScrollIndicator = false
        collection.showsHorizontalScrollIndicator = false
        collection.alwaysBounceVertical = true
        collection.dataSource = context.coordinator
        collection.delegate = context.coordinator
        collection.prefetchDataSource = context.coordinator
        collection.register(UICollectionViewCell.self, forCellWithReuseIdentifier: Coordinator.reuseID)
        collection.onWidthChange = { [weak coordinator = context.coordinator, weak collection] in
            guard let coordinator, let collection else { return }
            coordinator.updateLayout(in: collection)
            coordinator.scheduleVisiblePageUpdate(in: collection)
        }
        context.coordinator.collection = collection
        return collection
    }

    func updateUIView(_ collection: UICollectionView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.isUpdating = true
        coordinator.updateItems(items, in: collection)
        coordinator.updateLayout(in: collection)
        coordinator.isUpdating = false
        coordinator.scheduleVisiblePageUpdate(in: collection)
    }

    final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegate,
                             UICollectionViewDataSourcePrefetching {
        static var reuseID: String { "ReaderVerticalCell" }

        var parent: ReaderVerticalCollectionView
        weak var collection: UICollectionView?
        private var displayedItems: [ReaderVerticalItem] = []
        private var imageSizes: [ReaderVerticalItem: CGSize] = [:]
        private var appliedScale: CGFloat = 1
        private var appliedGap: CGFloat = 0
        private var appliedWidth: CGFloat = 0
        private var lastVisiblePage: (Int, Int)?
        private var appliedAppearanceRevision: Int?
        var isUpdating = false
        private var visibleUpdateQueued = false

        init(_ parent: ReaderVerticalCollectionView) { self.parent = parent }

        func updateItems(_ items: [ReaderVerticalItem], in collection: UICollectionView) {
            guard displayedItems != items else {
                if appliedAppearanceRevision != parent.appearanceRevision {
                    for cell in collection.visibleCells {
                        guard let path = collection.indexPath(for: cell) else { continue }
                        configure(cell, at: path.item)
                    }
                }
                appliedAppearanceRevision = parent.appearanceRevision
                return
            }

            let oldCount = displayedItems.count
            let extendsTail = oldCount > 0 && items.count > oldCount &&
                Array(items.prefix(oldCount)) == displayedItems
            displayedItems = items
            appliedAppearanceRevision = parent.appearanceRevision
            if extendsTail {
                let inserted = (oldCount..<items.count).map { IndexPath(item: $0, section: 0) }
                collection.performBatchUpdates {
                    collection.insertItems(at: inserted)
                }
            } else {
                lastVisiblePage = nil
                imageSizes = [:]
                collection.reloadData()
                collection.setContentOffset(.zero, animated: false)
            }
        }

        func updateLayout(in collection: UICollectionView) {
            let width = collection.bounds.width
            let newScale = max(1, parent.scale)
            let newGap = max(0, parent.gap)
            guard appliedScale != newScale || appliedGap != newGap || appliedWidth != width else { return }
            preservingVisiblePosition(in: collection) {
                appliedScale = newScale
                appliedGap = newGap
                appliedWidth = width
                if let layout = collection.collectionViewLayout as? ReaderVerticalLayout {
                    layout.scale = newScale
                    layout.gap = newGap
                }
            }
        }

        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
            displayedItems.count
        }

        func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: Self.reuseID, for: indexPath)
            configure(cell, at: indexPath.item)
            return cell
        }

        private func configure(_ cell: UICollectionViewCell, at index: Int) {
            guard displayedItems.indices.contains(index) else { return }
            let item = displayedItems[index]
            let displayWidth = max(1, (collection?.bounds.width ?? 1) * max(1, parent.scale))
            cell.contentConfiguration = UIHostingConfiguration {
                parent.content(item, displayWidth) { [weak self] size in
                    self?.recordImageSize(size, for: item)
                }
            }
            .margins(.all, 0)
        }

        private func recordImageSize(_ size: CGSize, for item: ReaderVerticalItem) {
            guard size.width > 0, size.height > 0, displayedItems.contains(item),
                  imageSizes[item] != size,
                  let collection else { return }
            preservingVisiblePosition(in: collection) { imageSizes[item] = size }
            scheduleVisiblePageUpdate(in: collection)
        }

        private func preservingVisiblePosition(in collection: UICollectionView, update: () -> Void) {
            let center = CGPoint(x: collection.contentOffset.x + collection.bounds.midX,
                                 y: collection.contentOffset.y + collection.bounds.midY)
            let path = collection.indexPathForItem(at: center) ?? collection.indexPathsForVisibleItems.first
            let anchor = path.flatMap { path -> (IndexPath, CGFloat, CGFloat)? in
                guard let frame = collection.layoutAttributesForItem(at: path)?.frame,
                      frame.width > 0, frame.height > 0 else { return nil }
                return (path, (center.x - frame.minX) / frame.width, (center.y - frame.minY) / frame.height)
            }

            update()
            collection.collectionViewLayout.invalidateLayout()
            collection.layoutIfNeeded()

            if let (path, fractionX, fractionY) = anchor,
               let frame = collection.layoutAttributesForItem(at: path)?.frame {
                let x = frame.minX + frame.width * fractionX - collection.bounds.midX
                let y = frame.minY + frame.height * fractionY - collection.bounds.midY
                let maxX = max(0, collection.contentSize.width - collection.bounds.width)
                let maxY = max(0, collection.contentSize.height - collection.bounds.height)
                collection.contentOffset = CGPoint(x: min(max(0, x), maxX), y: min(max(0, y), maxY))
            }
        }

        func sizeForItem(at index: Int, width: CGFloat) -> CGSize {
            guard displayedItems.indices.contains(index) else { return .zero }
            let item = displayedItems[index]
            switch item {
            case .page(_, _, let page):
                if let size = imageSizes[item], size.width > 0 {
                    return CGSize(width: width, height: width * size.height / size.width)
                }
                if let pageWidth = page.width, let pageHeight = page.height,
                   pageWidth > 0, pageHeight > 0 {
                    return CGSize(width: width, height: width * CGFloat(pageHeight) / CGFloat(pageWidth))
                }
                return CGSize(width: width, height: 480)
            case .footer:
                return CGSize(width: width, height: 120)
            }
        }

        func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell,
                            forItemAt indexPath: IndexPath) {
            guard displayedItems.indices.contains(indexPath.item) else { return }
            if case .footer(let chapterIndex) = displayedItems[indexPath.item] {
                parent.onFooter(chapterIndex)
            }
        }

        func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
            let positions = indexPaths.compactMap { path -> (Int, Int)? in
                guard displayedItems.indices.contains(path.item),
                      case .page(let chapterIndex, let pageIndex, _) = displayedItems[path.item] else { return nil }
                return (chapterIndex, pageIndex)
            }
            if !positions.isEmpty { parent.onPrefetch(positions) }
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard !isUpdating, let collection = scrollView as? UICollectionView else { return }
            updateVisiblePage(in: collection)
        }

        func scheduleVisiblePageUpdate(in collection: UICollectionView) {
            guard !visibleUpdateQueued else { return }
            visibleUpdateQueued = true
            DispatchQueue.main.async { [weak self, weak collection] in
                self?.visibleUpdateQueued = false
                guard let self, let collection, !self.isUpdating else { return }
                self.updateVisiblePage(in: collection)
            }
        }

        func updateVisiblePage(in collection: UICollectionView) {
            let viewportCenter = collection.contentOffset.y + collection.bounds.midY
            let nearest = collection.indexPathsForVisibleItems.compactMap { path -> (Int, Int, CGFloat)? in
                guard displayedItems.indices.contains(path.item),
                      case .page(let chapterIndex, let pageIndex, _) = displayedItems[path.item],
                      let frame = collection.layoutAttributesForItem(at: path)?.frame else { return nil }
                return (chapterIndex, pageIndex, abs(frame.midY - viewportCenter))
            }.min(by: { $0.2 < $1.2 })
            guard let nearest else { return }
            let position = (nearest.0, nearest.1)
            guard lastVisiblePage?.0 != position.0 || lastVisiblePage?.1 != position.1 else { return }
            lastVisiblePage = position
            parent.onVisiblePage(position.0, position.1)
        }

        func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                       targetContentOffset: UnsafeMutablePointer<CGPoint>) {
            guard parent.scale == 1, abs(velocity.y) > 0.01 else { return }
            let maxY = max(0, scrollView.contentSize.height - scrollView.bounds.height)
            targetContentOffset.pointee.y = ReaderScrollInertia.destination(
                current: scrollView.contentOffset.y,
                proposed: targetContentOffset.pointee.y,
                multiplier: parent.inertiaMultiplier,
                lowerBound: 0,
                upperBound: maxY
            )
        }
    }
}

private final class VerticalReaderCollectionView: UICollectionView {
    var onWidthChange: (() -> Void)?
    private var previousWidth: CGFloat = 0

    override func layoutSubviews() {
        let widthChanged = previousWidth != bounds.width
        previousWidth = bounds.width
        super.layoutSubviews()
        if widthChanged, bounds.width > 0 { onWidthChange?() }
    }
}

private final class ReaderVerticalLayout: UICollectionViewLayout {
    var scale: CGFloat = 1
    var gap: CGFloat = 0
    var sizeForItem: ((Int, CGFloat) -> CGSize)?
    private var attributes: [UICollectionViewLayoutAttributes] = []
    private var measuredContentSize: CGSize = .zero

    override func prepare() {
        super.prepare()
        guard let collectionView else { return }
        let width = max(1, collectionView.bounds.width * scale)
        var y: CGFloat = 0
        attributes = []
        let count = collectionView.numberOfItems(inSection: 0)
        for index in 0..<count {
            let path = IndexPath(item: index, section: 0)
            let height = max(1, sizeForItem?(index, width).height ?? 1)
            let attribute = UICollectionViewLayoutAttributes(forCellWith: path)
            attribute.frame = CGRect(x: 0, y: y, width: width, height: height)
            attributes.append(attribute)
            y += height + gap
        }
        measuredContentSize = CGSize(width: width, height: max(0, y - (count > 0 ? gap : 0)))
    }

    override var collectionViewContentSize: CGSize { measuredContentSize }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        attributes.filter { $0.frame.intersects(rect) }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard attributes.indices.contains(indexPath.item) else { return nil }
        return attributes[indexPath.item]
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        newBounds.width != collectionView?.bounds.width
    }
}
