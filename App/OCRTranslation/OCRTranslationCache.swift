import Foundation

/// Identifies one page's OCR+translation result. `engineVersion` is bumped
/// whenever the clustering algorithm or Stage-A/B prompts change, so old
/// cached results are naturally ignored instead of showing stale text.
struct OCRCacheKey: Hashable {
    let site: ExternalSite
    let galleryId: Int
    /// The field that actually disambiguates pages — confirmed some
    /// providers (ThreeHentai, Imhentai) reuse the exact same
    /// `ExternalGalleryPage.key` for EVERY page in a gallery (there it
    /// doubles as the page-image-URL host+path formula, so it can't be
    /// changed to vary per page), which used to collide every page in
    /// those galleries onto one cached translation. `index` is always a
    /// plain per-page loop counter in every provider, so it's the one
    /// field guaranteed unique.
    let pageIndex: Int
    /// Kept alongside `pageIndex` for extra specificity (e.g. Hitomi's
    /// real per-file hash) but never relied on alone — see `pageIndex`.
    let pageKey: String
    let sourceLanguage: String
    let targetLanguage: String
    let engineVersion: Int

    static let currentEngineVersion = 6

    var diskFileName: String {
        "\(pageIndex)_\(sourceLanguage)_\(targetLanguage)_v\(engineVersion).json"
    }
}

struct CachedPageTranslation: Codable {
    let blocks: [RecognizedTextBlock]
    var stageAText: [String: String] // keyed by RecognizedTextBlock.id.uuidString
    var stageBText: [String: String]
    /// The prompt template Stage B was actually run with — lets
    /// OCRTranslationEngine.attemptStageB tell "already done, nothing to
    /// do" apart from "done with a prompt the user has since edited,
    /// needs a redo" (previously ANY non-empty stageBText short-circuited
    /// a retry forever, so editing the custom prompt in Settings had no
    /// visible effect on already-cached pages — "написал кастомный
    /// промт, а он по прежнему не переводил").
    var stageBPrompt: String = ""
    /// The source page image's pixel size at OCR time — persisted so a
    /// LATER Stage-B attempt (re-run purely from cache, no image at hand,
    /// see OCRTranslationEngine.runStageB) can still work out each
    /// block's approximate original on-screen footprint
    /// (RecognizedTextBlock.characterBudget(imageSize:)) to hint the
    /// rephrase prompt toward text that fits.
    let imageSize: CGSize

    func text(for blockID: UUID) -> String? {
        stageBText[blockID.uuidString] ?? stageAText[blockID.uuidString]
    }
}

/// In-memory tier — cheap, per-session, no persistence.
final class OCRTranslationMemoryCache {
    static let shared = OCRTranslationMemoryCache()
    private let cache = NSCache<NSString, Box>()

    private final class Box { let value: CachedPageTranslation; init(_ value: CachedPageTranslation) { self.value = value } }

    private func key(_ key: OCRCacheKey) -> NSString { NSString(string: key.diskFileName + "_\(key.site.rawValue)_\(key.galleryId)") }

    subscript(_ key: OCRCacheKey) -> CachedPageTranslation? {
        get { cache.object(forKey: self.key(key))?.value }
        set {
            guard let newValue else { cache.removeObject(forKey: self.key(key)); return }
            cache.setObject(Box(newValue), forKey: self.key(key))
        }
    }
}

/// Disk tier — regeneratable JSON files under Library/Caches, swept
/// automatically by the app's existing "Очистить кеш" (StorageSettingsView
/// already walks the whole cachesDirectory), no extra cleanup code needed.
actor OCRTranslationDiskCache {
    static let shared = OCRTranslationDiskCache()

    private func directory(for key: OCRCacheKey) -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("OCRTranslations", isDirectory: true)
            .appendingPathComponent(key.site.rawValue, isDirectory: true)
            .appendingPathComponent(String(key.galleryId), isDirectory: true)
    }

    private func fileURL(for key: OCRCacheKey) -> URL {
        directory(for: key).appendingPathComponent(key.diskFileName)
    }

    func load(_ key: OCRCacheKey) -> CachedPageTranslation? {
        guard let data = try? Data(contentsOf: fileURL(for: key)) else { return nil }
        return try? JSONDecoder().decode(CachedPageTranslation.self, from: data)
    }

    func save(_ key: OCRCacheKey, _ value: CachedPageTranslation) {
        let dir = directory(for: key)
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: fileURL(for: key), options: .atomic)
    }
}
