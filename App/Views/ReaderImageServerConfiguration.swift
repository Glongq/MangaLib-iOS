import Foundation

/// Resolve image hosts before an online chapter exposes its page URLs to the reader.
@MainActor
enum ReaderImageServerConfiguration {
    private static var request: Task<Void, Never>?
    private static let imageServerIDs: Set<String> = ["main", "secondary", "compress", "download"]

    static func isAvailable(for siteId: Int) -> Bool {
        MangaImageURL.realServers.contains {
            $0.siteIds.contains(siteId) && imageServerIDs.contains($0.id) && !$0.url.isEmpty
        }
    }

    static func ensureAvailable(for siteId: Int) async -> Bool {
        if isAvailable(for: siteId) { return true }

        if let request {
            await request.value
            return isAvailable(for: siteId)
        }

        let newRequest = Task {
            do {
                let payload = try await MangaNetworkService.shared.fetchConstants()
                if let servers = payload.imageServers {
                    MangaImageURL.updateServers(fromAccount: servers)
                }
            } catch {
                // The caller shows a retryable error when no server is available.
            }
        }
        request = newRequest
        await newRequest.value
        request = nil
        return isAvailable(for: siteId)
    }
}
