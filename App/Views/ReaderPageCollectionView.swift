import SwiftUI
import UIKit

/// A native page scroller that keeps the reader's existing SwiftUI page content.
struct ReaderPageCollectionView<Content: View>: UIViewRepresentable {
    let chapterIndex: Int
    let pageCount: Int
    let hasPrevious: Bool
    let hasNext: Bool
    let selectedPage: Int
    let isScrollEnabled: Bool
    let contentRevision: Int
    let transitionProgress: Double?
    let onSelect: (Int) -> Void
    let content: (Int) -> Content

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UICollectionView {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0
        let collection = PagingCollectionView(frame: .zero, collectionViewLayout: layout)
        collection.backgroundColor = .clear
        collection.contentInsetAdjustmentBehavior = .never
        collection.isPagingEnabled = true
        collection.isScrollEnabled = isScrollEnabled
        collection.isPrefetchingEnabled = false
        collection.showsHorizontalScrollIndicator = false
        collection.showsVerticalScrollIndicator = false
        collection.dataSource = context.coordinator
        collection.delegate = context.coordinator
        collection.register(UICollectionViewCell.self, forCellWithReuseIdentifier: Coordinator.reuseID)
        collection.onSizeChange = { [weak coordinator = context.coordinator, weak collection] in
            guard let coordinator, let collection,
                  let item = coordinator.item(for: coordinator.parent.selectedPage),
                  collection.numberOfItems(inSection: 0) > item else { return }
            coordinator.displayedPage = coordinator.parent.selectedPage
            collection.scrollToItem(at: IndexPath(item: item, section: 0), at: .centeredHorizontally, animated: false)
        }
        context.coordinator.collection = collection
        return collection
    }

    func updateUIView(_ collection: UICollectionView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        collection.isScrollEnabled = isScrollEnabled
        let identity = Coordinator.Identity(
            chapterIndex: chapterIndex,
            pageCount: pageCount,
            hasPrevious: hasPrevious,
            hasNext: hasNext
        )
        let identityChanged = coordinator.identity != identity
        if identityChanged {
            coordinator.identity = identity
            coordinator.displayedPage = nil
            collection.reloadData()
            collection.layoutIfNeeded()
        } else if coordinator.contentRevision != contentRevision ||
                    coordinator.transitionProgress != transitionProgress {
            for cell in collection.visibleCells {
                guard let indexPath = collection.indexPath(for: cell) else { continue }
                let page = coordinator.page(for: indexPath.item)
                let isTransition = page == 0 || page == pageCount + 2
                guard coordinator.contentRevision != contentRevision || isTransition else { continue }
                coordinator.configure(cell, at: indexPath.item)
            }
        }
        coordinator.contentRevision = contentRevision
        coordinator.transitionProgress = transitionProgress

        guard !collection.isDragging, !collection.isDecelerating,
              let item = coordinator.item(for: selectedPage),
              coordinator.displayedPage != selectedPage else { return }
        coordinator.displayedPage = selectedPage
        collection.scrollToItem(at: IndexPath(item: item, section: 0), at: .centeredHorizontally,
                                animated: !identityChanged && context.transaction.animation != nil)
    }

    final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
        static var reuseID: String { "ReaderPageCell" }

        struct Identity: Equatable {
            let chapterIndex: Int
            let pageCount: Int
            let hasPrevious: Bool
            let hasNext: Bool
        }

        var parent: ReaderPageCollectionView
        weak var collection: UICollectionView?
        var identity: Identity?
        var displayedPage: Int?
        var contentRevision: Int?
        var transitionProgress: Double?
        private var dragStartItem: Int?

        init(_ parent: ReaderPageCollectionView) { self.parent = parent }

        private var firstPage: Int { parent.hasPrevious ? 0 : 1 }
        private var lastPage: Int { parent.pageCount + 1 + (parent.hasNext ? 1 : 0) }

        func item(for page: Int) -> Int? {
            guard (firstPage...lastPage).contains(page) else { return nil }
            return page - firstPage
        }

        func page(for item: Int) -> Int { item + firstPage }

        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
            lastPage - firstPage + 1
        }

        func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: Self.reuseID, for: indexPath)
            configure(cell, at: indexPath.item)
            return cell
        }

        func configure(_ cell: UICollectionViewCell, at item: Int) {
            cell.contentConfiguration = UIHostingConfiguration {
                parent.content(page(for: item))
            }
            .margins(.all, 0)
        }

        func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout,
                            sizeForItemAt indexPath: IndexPath) -> CGSize {
            CGSize(width: max(1, collectionView.bounds.width), height: max(1, collectionView.bounds.height))
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { settle(scrollView) }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            guard scrollView.bounds.width > 0 else { return }
            dragStartItem = Int((scrollView.contentOffset.x / scrollView.bounds.width).rounded())
        }

        func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                       targetContentOffset: UnsafeMutablePointer<CGPoint>) {
            guard let dragStartItem, scrollView.bounds.width > 0 else { return }
            let target = Int((targetContentOffset.pointee.x / scrollView.bounds.width).rounded())
            let lastItem = lastPage - firstPage
            let bounded = min(max(target, dragStartItem - 1), dragStartItem + 1)
            targetContentOffset.pointee.x = CGFloat(min(max(bounded, 0), lastItem)) * scrollView.bounds.width
            self.dragStartItem = nil
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate { settle(scrollView) }
        }

        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { settle(scrollView) }

        private func settle(_ scrollView: UIScrollView) {
            guard scrollView.bounds.width > 0 else { return }
            let itemIndex = Int((scrollView.contentOffset.x / scrollView.bounds.width).rounded())
            let page = page(for: itemIndex)
            guard item(for: page) != nil, displayedPage != page else { return }
            displayedPage = page
            parent.onSelect(page)
        }
    }
}

private final class PagingCollectionView: UICollectionView {
    var onSizeChange: (() -> Void)?
    private var previousSize: CGSize = .zero

    override func layoutSubviews() {
        let sizeChanged = bounds.size != previousSize
        if sizeChanged {
            previousSize = bounds.size
            collectionViewLayout.invalidateLayout()
        }
        super.layoutSubviews()
        if sizeChanged, bounds.width > 0 { onSizeChange?() }
    }
}
