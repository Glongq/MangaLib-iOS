import SwiftUI
import UIKit

/// A vertically paged gallery feed. Each gallery contains its own horizontal reader.
struct ExternalRecommendationFeedView: View {
    let onBack: () -> Void
    @StateObject private var model = ExternalRecommendationFeedModel()
    @ObservedObject private var session = ExternalSiteSession.shared
    @ObservedObject private var filters = ExternalCatalogFilterStore.shared
    @ObservedObject private var recommendations = ExternalRecommendationStore.shared
    @ObservedObject private var bookmarks = ExternalBookmarksStore.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedID: String?
    @State private var tagsItem: ExternalRecommendationFeedItem?
    @State private var detailItem: ExternalRecommendationFeedItem?
    @State private var showPreferences = false
    @State private var isZoomed = false
    @State private var isVisible = false

    private var sites: [ExternalSite] {
        if let site = session.activeExternalSite { return [site] }
        return ExternalSite.allCases.filter { session.enabledSites.contains($0) }
    }

    private var filter: ExternalRecommendationFeedFilter {
        .current(combined: session.combinedModeActive)
    }

    private var isReading: Bool {
        isVisible && scenePhase == .active && tagsItem == nil && detailItem == nil && !showPreferences
    }

    private var nextItem: ExternalRecommendationFeedItem? {
        guard let current = selectedID ?? model.activeID,
              let index = model.items.firstIndex(where: { $0.id == current }), index + 1 < model.items.count else { return nil }
        return model.items[index + 1]
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Color.black
                if !model.items.isEmpty {
                    feed(size: geometry.size)
                } else {
                    emptyState
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(32)
                }
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                        .background(.black.opacity(0.45), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Назад")
                .padding(.leading, 16)
                .padding(.top, 8)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .toolbar(.hidden, for: .tabBar)
        .preferredColorScheme(.dark)
        .onAppear {
            isVisible = true
        }
        .onDisappear {
            isVisible = false
            model.stop()
        }
        .onChange(of: sites) { _, _ in resume() }
        .onChange(of: filter) { _, _ in resume() }
        .onChange(of: isReading, initial: true) { _, reading in
            if reading { resume() }
            else { model.stop() }
        }
        .onChange(of: selectedID) { _, id in
            isZoomed = false
            if let id { model.activate(id) }
        }
        .onChange(of: model.activeID) { _, id in
            if selectedID != id { selectedID = id }
        }
        .onChange(of: recommendations.revision) { _, _ in model.didChangePreferences() }
        .onChange(of: bookmarks.bookmarks) { _, _ in
            model.synchronizeBookmarks()
            model.didChangePreferences()
        }
        .task(id: isReading ? nextItem?.id : nil) {
            guard isReading, let nextItem, let page = nextItem.detail.pages.first else { return }
            let provider = ExternalSiteRegistry.provider(for: nextItem.detail.site)
            // Reuse the same resolved URL and image cache when this gallery becomes visible.
            _ = await resolveExternalPageURL(provider: provider, galleryId: nextItem.detail.id, page: page, readerPriority: false)
        }
        .sheet(item: $tagsItem) { item in
            ExternalRecommendationTagsSheet(document: item.document)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showPreferences) {
            ExternalRecommendationTagsSheet(document: nil)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $detailItem, onDismiss: {
            model.synchronizeBookmarks()
        }) { item in
            NavigationStack {
                ExternalGalleryDetailView(site: item.detail.site, id: item.detail.id, preloaded: item.isComplete ? item.detail : nil)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Назад", systemImage: "chevron.left") { detailItem = nil }
                        }
                    }
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
    }

    private func feed(size: CGSize) -> some View {
        let snapshot = model.items
        let currentID = selectedID ?? model.activeID
        return ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(snapshot) { item in
                    let active = currentID == item.id
                    ExternalRecommendationCard(
                        item: item,
                        isSelected: active,
                        isReading: active && isReading,
                        shouldPreload: isReading && active,
                        loadingPages: model.loadingPagesID == item.id,
                        pageListFailed: model.pageListErrorID == item.id,
                        loadingNext: snapshot.last?.id == item.id && model.isLoading,
                        canRetryNext: snapshot.last?.id == item.id && !model.isLoading && model.errorMessage != nil,
                        onRetryPages: { model.retryActivePages() },
                        onRetryNext: { model.retry() },
                        onShowTags: { tagsItem = item },
                        onOpenDetail: { detailItem = item },
                        onZoom: { zoomed in if active { isZoomed = zoomed } }
                    )
                    .frame(width: size.width, height: size.height)
                    .clipped()
                    .id(item.id)
                }
            }
            .scrollTargetLayout()
        }
        .scrollIndicators(.hidden)
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $selectedID, anchor: .top)
        .scrollDisabled(isZoomed)
        .onScrollPhaseChange { _, phase in model.setPaging(phase != .idle) }
        .frame(width: size.width, height: size.height)
        .clipped()
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.isLoading {
            VStack(spacing: 14) {
                ProgressView().tint(.white)
                Text("Подбираем тайтлы для тебя").font(.subheadline).foregroundStyle(.white.opacity(0.7))
            }
        } else {
            VStack(spacing: 20) {
                Image(systemName: "sparkles").font(.largeTitle)
                Text(model.errorMessage ?? "Включи сайты в меню, чтобы открыть рекомендации.")
                    .font(.subheadline).multilineTextAlignment(.center)
                HStack(spacing: 20) {
                    Button("Повторить") { model.retry() }
                    if !recommendations.profile.preferences.isEmpty {
                        Button("Предпочтения") { showPreferences = true }
                    }
                }
                .buttonStyle(.bordered)
            }
            .foregroundStyle(.white)
        }
    }

    private func resume() {
        guard isReading else { return }
        model.start(sites: sites, filter: filter)
    }
}

private struct ExternalRecommendationPagesRevision: Hashable {
    let selection: Int
    let selected: Bool
    let preload: Bool
}

private struct ExternalRecommendationCard: View {
    let item: ExternalRecommendationFeedItem
    let isSelected: Bool
    let isReading: Bool
    let shouldPreload: Bool
    let loadingPages: Bool
    let pageListFailed: Bool
    let loadingNext: Bool
    let canRetryNext: Bool
    let onRetryPages: () -> Void
    let onRetryNext: () -> Void
    let onShowTags: () -> Void
    let onOpenDetail: () -> Void
    let onZoom: (Bool) -> Void
    @ObservedObject private var store = ExternalRecommendationStore.shared
    @StateObject private var pagePreloader = ExternalPagePrefetcher()
    @State private var pageIndex = 0
    @State private var readyPages = Set<Int>()
    @State private var readPages = Set<Int>()
    @State private var intervalStart: TimeInterval?
    @State private var intervalPage: Int?
    @State private var pageSeconds: [Int: Double] = [:]
    @State private var visibleSeconds = 0.0
    @State private var hasRecordedImpression = false
    @State private var zoomed = false

    private var vote: ExternalRecommendationVote? { store.vote(for: item.document) }
    private var summaryTags: [ExternalRecommendationFeature] {
        let tags = item.document.uniqueFeatures.filter { $0.kind.isTag }
        return tags.filter { store.preference(for: $0) == .prefer }
            + tags.filter { store.preference(for: $0) != .prefer }
    }

    private struct PrefetchRequest: Equatable {
        let enabled: Bool
        let pageIndex: Int
        let pageCount: Int
    }

    var body: some View {
        VStack(spacing: 0) {
            ExternalRecommendationPagePager(
                ids: item.detail.pages.map { String($0.index) }, selection: $pageIndex, zoomed: zoomed,
                revision: ExternalRecommendationPagesRevision(selection: pageIndex, selected: isSelected, preload: shouldPreload)
            ) { index in
                ExternalRecommendationImagePage(
                        site: item.detail.site, galleryID: item.detail.id, page: item.detail.pages[index],
                        shouldLoad: shouldPreload && abs(index - pageIndex) <= (isSelected ? 1 : 0),
                        isCurrent: isSelected && index == pageIndex,
                        onLoaded: { loaded in
                            if loaded { readyPages.insert(index) }
                            else { readyPages.remove(index) }
                            updateExposure()
                        },
                        onZoom: { value in
                            if index == pageIndex {
                                zoomed = value
                                onZoom(value)
                            }
                        }
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, 20)

            // Reserve space for controls so page text is never hidden underneath them.
            bottomControls
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.black)
        }
        .background(.black)
        .task(id: PrefetchRequest(enabled: isReading && shouldPreload, pageIndex: pageIndex, pageCount: item.detail.pages.count)) {
            guard isReading && shouldPreload else { pagePreloader.cancel(); return }
            pagePreloader.update(
                provider: ExternalSiteRegistry.provider(for: item.detail.site),
                galleryID: item.detail.id, pages: item.detail.pages, currentIndex: pageIndex
            )
        }
        .onChange(of: pageIndex) { _, _ in
            zoomed = false
            onZoom(false)
            updateExposure()
        }
        .onChange(of: isReading) { _, _ in
            updateExposure()
            if !isReading {
                commitExposure()
                zoomed = false
                onZoom(false)
            }
        }
        .onChange(of: isSelected) { _, selected in
            if selected {
                finishInterval()
                visibleSeconds = 0
                readPages = []
                pageSeconds = [:]
                hasRecordedImpression = false
                updateExposure()
            } else {
                updateExposure()
                commitExposure()
                zoomed = false
            }
        }
        .onDisappear {
            pagePreloader.cancel()
            finishInterval()
            commitExposure()
        }
    }

    private var bottomControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(item.detail.site.displayName)
                Text("·")
                Text("\(pageIndex + 1) / \(item.document.pageCount)")
                    .monospacedDigit()
                Spacer()
                if loadingPages {
                    ProgressView().tint(.white).controlSize(.mini)
                        .accessibilityLabel("Загружаются остальные страницы")
                } else if pageListFailed {
                    Button("Догрузить страницы", systemImage: "arrow.clockwise", action: onRetryPages)
                        .font(.caption)
                        .foregroundStyle(.white)
                } else if loadingNext {
                    ProgressView().tint(.white).controlSize(.mini)
                        .accessibilityLabel("Подбираются следующие тайтлы")
                } else if canRetryNext {
                    Button("Ещё тайтлы", systemImage: "arrow.clockwise", action: onRetryNext)
                        .font(.caption)
                        .foregroundStyle(.white)
                }
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.white.opacity(0.65))
            .accessibilityLabel("Страница \(pageIndex + 1) из \(item.document.pageCount)")

            Text(item.detail.title)
                .font(.headline)
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !item.detail.artists.isEmpty {
                Button(action: onShowTags) {
                    Text(item.detail.artists.joined(separator: ", "))
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .foregroundStyle(.white.opacity(0.8))
                }
                .buttonStyle(.plain)
                .accessibilityHint("Предпочтения по авторам")
            }

            HStack(spacing: 5) {
                Text(summaryTags.map { "#\($0.sharedValue)" }.joined(separator: " "))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Ещё", action: onShowTags)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.white.opacity(0.12), in: Capsule())
                    .fixedSize()
                    .accessibilityLabel("Все теги и предпочтения")
            }

            HStack(spacing: 12) {
                reactionButton(symbol: vote == .like ? "heart.fill" : "heart", label: "Нравится", selected: vote == .like, color: .pink) {
                    store.toggleVote(.like, for: item.document)
                }
                reactionButton(symbol: vote == .dislike ? "hand.thumbsdown.fill" : "hand.thumbsdown", label: "Не нравится", selected: vote == .dislike, color: .white) {
                    store.toggleVote(.dislike, for: item.document)
                }
                Button(action: onOpenDetail) {
                    Text("Читать")
                        .font(.headline)
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(.white, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Открыть карточку тайтла")
            }
        }
    }

    private func reactionButton(symbol: String, label: String, selected: Bool, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 23, weight: .medium))
                .foregroundStyle(selected ? color : .white)
                .frame(width: 50, height: 50)
                .background(.white.opacity(selected ? 0.22 : 0.12), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func finishInterval() {
        if let start = intervalStart {
            let elapsed = max(0, ProcessInfo.processInfo.systemUptime - start)
            visibleSeconds += elapsed
            if let page = intervalPage {
                pageSeconds[page, default: 0] += elapsed
                if pageSeconds[page, default: 0] >= 1.2 { readPages.insert(page) }
            }
            intervalStart = nil
            intervalPage = nil
        }
    }

    private func updateExposure() {
        finishInterval()
        if isReading && readyPages.contains(pageIndex) {
            intervalPage = pageIndex
            intervalStart = ProcessInfo.processInfo.systemUptime
        }
    }

    private func commitExposure() {
        guard visibleSeconds >= 0.6 else { return }
        store.recordExposure(item.document, seconds: visibleSeconds, pages: readPages.count, incrementImpression: !hasRecordedImpression)
        hasRecordedImpression = true
    }
}

/// The horizontal image pager retains only the current page and its neighbors.
private struct ExternalRecommendationPagePager<Content: View>: UIViewControllerRepresentable {
    let ids: [String]
    @Binding var selection: Int
    let zoomed: Bool
    var orientation: UIPageViewController.NavigationOrientation = .horizontal
    let revision: AnyHashable
    var onTransitionChange: (Bool) -> Void = { _ in }
    @ViewBuilder let content: (Int) -> Content
    private var count: Int { ids.count }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let controller = UIPageViewController(transitionStyle: .scroll, navigationOrientation: orientation)
        controller.view.backgroundColor = .clear
        controller.view.clipsToBounds = true
        controller.dataSource = context.coordinator
        controller.delegate = context.coordinator
        if count > 0 {
            controller.setViewControllers([context.coordinator.host(for: min(selection, count - 1))], direction: .forward, animated: false)
        }
        context.coordinator.presentedIDs = ids
        return controller
    }

    func updateUIViewController(_ controller: UIPageViewController, context: Context) {
        let coordinator = context.coordinator
        let refresh = coordinator.parent.revision != revision || coordinator.parent.ids != ids
        coordinator.parent = self
        for scroll in controller.view.subviews.compactMap({ $0 as? UIScrollView }) {
            scroll.isScrollEnabled = !zoomed
            scroll.isDirectionalLockEnabled = true
            scroll.alwaysBounceVertical = false
            scroll.contentInsetAdjustmentBehavior = .never
            scroll.clipsToBounds = true
        }
        if refresh {
            for (id, host) in coordinator.hosts {
                if let index = ids.firstIndex(of: id) { host.rootView = content(index) }
            }
        }
        coordinator.synchronize(controller)
    }

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: ExternalRecommendationPagePager
        var hosts: [String: UIHostingController<Content>] = [:]
        var transitioning = false
        var presentedIDs: [String] = []
        var wasZoomed = false

        init(parent: ExternalRecommendationPagePager) { self.parent = parent }

        func host(for index: Int) -> UIHostingController<Content> {
            let id = parent.ids[index]
            if let host = hosts[id] { return host }
            let host = UIHostingController(rootView: parent.content(index))
            host.view.backgroundColor = .clear
            host.safeAreaRegions = []
            hosts[id] = host
            return host
        }

        func index(of controller: UIViewController) -> Int? {
            guard let id = hosts.first(where: { $0.value === controller })?.key else { return nil }
            return parent.ids.firstIndex(of: id)
        }

        func trim(around index: Int) {
            let keep = Set(parent.ids.enumerated().filter { abs($0.offset - index) <= 1 }.map(\.element))
            for key in hosts.keys where !keep.contains(key) { hosts.removeValue(forKey: key) }
        }

        func synchronize(_ controller: UIPageViewController, selectedIndex: Int? = nil) {
            guard parent.count > 0, !transitioning else { return }
            let target = min(max(0, selectedIndex ?? parent.selection), parent.count - 1)
            let current = controller.viewControllers?.first.flatMap { index(of: $0) }
            let neighborsChanged = presentedIDs != parent.ids || wasZoomed != parent.zoomed
            if neighborsChanged {
                // UIKit caches absent neighbors too. Reload when asynchronous results change the page list.
                controller.dataSource = nil
            }
            if neighborsChanged || target != current {
                controller.setViewControllers([host(for: target)], direction: target >= (current ?? target) ? .forward : .reverse, animated: false)
            }
            controller.dataSource = parent.zoomed ? nil : self
            presentedIDs = parent.ids
            wasZoomed = parent.zoomed
            trim(around: target)
        }

        func pageViewController(_ pageViewController: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
            guard let index = index(of: viewController), index > 0 else { return nil }
            return host(for: index - 1)
        }

        func pageViewController(_ pageViewController: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
            guard let index = index(of: viewController), index + 1 < parent.count else { return nil }
            return host(for: index + 1)
        }

        func pageViewController(_ pageViewController: UIPageViewController, willTransitionTo pendingViewControllers: [UIViewController]) {
            transitioning = true
            parent.onTransitionChange(true)
        }

        func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool, previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            transitioning = false
            if completed, let current = pageViewController.viewControllers?.first, let index = index(of: current) {
                parent.selection = index
                trim(around: index)
            }
            parent.onTransitionChange(false)
            if presentedIDs != parent.ids || wasZoomed != parent.zoomed {
                let current = pageViewController.viewControllers?.first.flatMap { index(of: $0) }
                synchronize(pageViewController, selectedIndex: current)
            }
        }
    }
}

/// Full-size pages use the established external headers and the native image zoom surface.
private struct ExternalRecommendationImagePage: View {
    let site: ExternalSite
    let galleryID: Int
    let page: ExternalGalleryPage
    let shouldLoad: Bool
    let isCurrent: Bool
    let onLoaded: (Bool) -> Void
    let onZoom: (Bool) -> Void
    @State private var url: URL?
    @State private var failed = false
    @State private var attempt = 0

    private struct LoadRequest: Equatable {
        let enabled: Bool
        let attempt: Int
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let url {
                    ZoomableImageScrollView(
                        candidates: [url], fitWidth: false, doubleTapZoom: true,
                        onTap: { _ in }, onZoomChanged: onZoom,
                        ringColor: .white, viewportHeight: geometry.size.height
                    )
                } else if shouldLoad {
                    if failed {
                        Button { attempt += 1 } label: {
                            Label("Повторить", systemImage: "arrow.clockwise")
                                .foregroundStyle(.white)
                                .padding(16)
                                .background(.white.opacity(0.12), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    } else {
                        ProgressView().tint(.white)
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .task(id: LoadRequest(enabled: shouldLoad, attempt: attempt)) {
            guard shouldLoad else {
                url = nil
                onLoaded(false)
                return
            }
            if url != nil { onLoaded(true); return }
            failed = false
            let provider = ExternalSiteRegistry.provider(for: site)
            let resolved = await resolveExternalPageURL(provider: provider, galleryId: galleryID, page: page, readerPriority: isCurrent)
            guard !Task.isCancelled else { return }
            url = resolved
            failed = resolved == nil
            onLoaded(resolved != nil)
        }
    }
}

private struct ExternalRecommendationTagsSheet: View {
    let document: ExternalRecommendationDocument?
    @ObservedObject private var store = ExternalRecommendationStore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(ExternalRecommendationFeature.Kind.allCases.filter { $0.sharedKind == $0 && $0 != .format }, id: \.self) { kind in
                    let features = (document?.uniqueFeatures ?? []).filter { $0.kind.sharedKind == kind }
                    if !features.isEmpty {
                        Section(sectionTitle(kind)) {
                            ForEach(features) { feature in featureRow(feature) }
                        }
                    }
                }
                if !store.profile.preferences.isEmpty {
                    Section("Мои предпочтения") {
                        ForEach(store.profile.preferences.values.sorted { $0.feature.id < $1.feature.id }, id: \.feature.id) { preference in
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(preference.feature.value)
                                    Text(preference.value == .hide ? "Реже" : "Больше такого")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Убрать") { store.setPreference(nil, for: preference.feature) }
                                    .font(.caption)
                            }
                        }
                    }
                }
                Section {
                    Text("Лайки и закладки усиливают интерес к тегам и авторам. Дизлайк убирает тайтл, а повторные дизлайки снижают похожие рекомендации. «Реже» снижает приоритет тега или автора, но не запрещает их.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Теги и предпочтения")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Готово") { dismiss() } }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func featureRow(_ feature: ExternalRecommendationFeature) -> some View {
        let preference = store.preference(for: feature)
        return HStack {
            Text(feature.alias.map { "\(feature.value) · \($0)" } ?? feature.value)
            Spacer()
            Menu {
                Button(preference == .prefer ? "Убрать предпочтение" : "Больше такого", systemImage: "heart") {
                    store.setPreference(preference == .prefer ? nil : .prefer, for: feature)
                }
                Button(preference == .hide ? "Убрать понижение" : "Реже", systemImage: "minus.circle") {
                    store.setPreference(preference == .hide ? nil : .hide, for: feature)
                }
            } label: {
                Image(systemName: preference == .hide ? "minus.circle.fill" : preference == .prefer ? "heart.fill" : "ellipsis")
                    .foregroundStyle(preference == .prefer ? Color.pink : Color.secondary)
                    .frame(width: 44, height: 36)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Предпочтение: \(feature.value)")
        }
    }

    private func sectionTitle(_ kind: ExternalRecommendationFeature.Kind) -> String {
        switch kind {
        case .tag, .female, .male: return "Теги"
        case .artist: return "Авторы"
        case .group: return "Группы"
        case .character: return "Персонажи"
        case .series: return "Серии"
        case .format: return "Тип"
        }
    }
}
