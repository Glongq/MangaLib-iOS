import Foundation
import Combine

private struct ExternalPageImageKey: Hashable {
    let siteID: String
    let galleryID: Int
    let index: Int
    let pageKey: String

    init(provider: any ExternalSiteProvider, galleryID: Int, page: ExternalGalleryPage) {
        siteID = provider.site.rawValue
        self.galleryID = galleryID
        index = page.index
        pageKey = page.key
    }
}

/// Reuse the exact resolved URL, including temporary E-Hentai links, when a prefetched page becomes visible.
private actor ExternalPageURLCache {
    static let shared = ExternalPageURLCache()
    private struct Entry {
        let url: URL
        let date: Date
    }
    private struct Resolution {
        let id: UUID
        let task: Task<URL, Error>
        var consumers: Set<UUID>
    }
    private var entries: [ExternalPageImageKey: Entry] = [:]
    private var resolutions: [ExternalPageImageKey: Resolution] = [:]

    func resolve(provider: any ExternalSiteProvider, galleryID: Int, page: ExternalGalleryPage) async throws -> URL {
        let key = ExternalPageImageKey(provider: provider, galleryID: galleryID, page: page)
        if let entry = entries[key], Date().timeIntervalSince(entry.date) < 600 { return entry.url }
        let consumer = UUID()
        let task: Task<URL, Error>
        let id: UUID
        if var resolution = resolutions[key] {
            resolution.consumers.insert(consumer)
            resolutions[key] = resolution
            id = resolution.id
            task = resolution.task
        } else {
            id = UUID()
            task = Task { try await provider.pageImageURL(galleryId: galleryID, page: page) }
            resolutions[key] = Resolution(id: id, task: task, consumers: [consumer])
        }
        return try await withTaskCancellationHandler {
            do {
                let url = try await task.value
                try Task.checkCancellation()
                if resolutions[key]?.id == id {
                    entries[key] = Entry(url: url, date: Date())
                    if entries.count > 96, let oldest = entries.min(by: { $0.value.date < $1.value.date })?.key {
                        entries.removeValue(forKey: oldest)
                    }
                }
                release(key, consumer: consumer)
                return url
            } catch {
                release(key, consumer: consumer)
                throw error
            }
        } onCancel: {
            Task { await self.release(key, consumer: consumer) }
        }
    }

    private func release(_ key: ExternalPageImageKey, consumer: UUID) {
        guard var resolution = resolutions[key], resolution.consumers.remove(consumer) != nil else { return }
        if resolution.consumers.isEmpty {
            resolutions[key] = nil
            resolution.task.cancel()
        } else {
            resolutions[key] = resolution
        }
    }

    func invalidate(provider: any ExternalSiteProvider, galleryID: Int, page: ExternalGalleryPage, failedURL: URL) {
        let key = ExternalPageImageKey(provider: provider, galleryID: galleryID, page: page)
        if entries[key]?.url == failedURL { entries[key] = nil }
    }
}

/// Share an in-flight download without letting a disappearing page cancel another consumer's image.
private actor ExternalPageImageDownloads {
    static let shared = ExternalPageImageDownloads()
    private struct Flight {
        let task: Task<Bool, Never>
        var consumers: Set<UUID>
    }
    private var flights: [URL: Flight] = [:]

    func load(_ url: URL, bypassNetworkCache: Bool, readerPriority: Bool) async -> Bool {
        let consumer = UUID()
        let task: Task<Bool, Never>
        if var flight = flights[url] {
            flight.consumers.insert(consumer)
            flights[url] = flight
            task = flight.task
        } else {
            task = Task(priority: readerPriority ? .userInitiated : .utility) {
                await preloadExternalImage(url, bypassNetworkCache: bypassNetworkCache, readerPriority: readerPriority)
            }
            flights[url] = Flight(task: task, consumers: [consumer])
        }
        return await withTaskCancellationHandler {
            let loaded = await task.value
            release(url, consumer: consumer)
            return loaded && !Task.isCancelled
        } onCancel: {
            Task { await self.release(url, consumer: consumer) }
        }
    }

    private func release(_ url: URL, consumer: UUID) {
        guard var flight = flights[url], flight.consumers.remove(consumer) != nil else { return }
        if flight.consumers.isEmpty {
            flights[url] = nil
            flight.task.cancel()
        } else {
            flights[url] = flight
        }
    }
}

/// Visible pages and prefetches share URL resolution, image caches, site headers and routing refresh.
func resolveExternalPageURL(
    provider: any ExternalSiteProvider,
    galleryId: Int,
    page: ExternalGalleryPage,
    readerPriority: Bool = true
) async -> URL? {
    let attempts = readerPriority ? 5 : 2
    for attempt in 0..<attempts {
        guard !Task.isCancelled else { return nil }
        if let url = try? await ExternalPageURLCache.shared.resolve(provider: provider, galleryID: galleryId, page: page) {
            guard !Task.isCancelled else { return nil }
            if await ExternalPageImageDownloads.shared.load(url, bypassNetworkCache: attempt > 0, readerPriority: readerPriority) {
                return Task.isCancelled ? nil : url
            }
            guard !Task.isCancelled else { return nil }
            await ExternalPageURLCache.shared.invalidate(provider: provider, galleryID: galleryId, page: page, failedURL: url)
            await provider.pageImageLoadFailed(galleryId: galleryId, page: page, url: url)
        }
        if attempt + 1 < attempts {
            do { try await Task.sleep(for: .milliseconds(350 * (1 << min(attempt, 3)))) }
            catch { return nil }
        }
    }
    return nil
}

/// Own exactly three forward jobs independently of which page views UIKit happens to mount.
@MainActor
final class ExternalPagePrefetcher: ObservableObject {
    static let aheadCount = 3
    private struct Job {
        let id: UUID
        let task: Task<Void, Never>
    }
    private var jobs: [ExternalPageImageKey: Job] = [:]

    func update(provider: any ExternalSiteProvider, galleryID: Int, pages: [ExternalGalleryPage], currentIndex: Int) {
        let start = max(0, currentIndex + 1)
        let end = min(pages.count, start + Self.aheadCount)
        let upcoming = start < end ? Array(pages[start..<end]) : []
        let desired = Set(upcoming.map { ExternalPageImageKey(provider: provider, galleryID: galleryID, page: $0) })
        for key in Array(jobs.keys) where !desired.contains(key) {
            jobs.removeValue(forKey: key)?.task.cancel()
        }
        for page in upcoming {
            let key = ExternalPageImageKey(provider: provider, galleryID: galleryID, page: page)
            guard jobs[key] == nil else { continue }
            let id = UUID()
            let task = Task(priority: .utility) { [weak self] in
                let url = await resolveExternalPageURL(provider: provider, galleryId: galleryID, page: page, readerPriority: false)
                if url == nil, self?.jobs[key]?.id == id { self?.jobs[key] = nil }
            }
            jobs[key] = Job(id: id, task: task)
        }
    }

    func cancel() {
        for job in jobs.values { job.task.cancel() }
        jobs.removeAll()
    }
}
