import Foundation

/// Legacy Google values remain only to preserve the inactive settings controls.
enum OCRRecognitionProvider: Int, CaseIterable {
    case appleVision = 0
    case googleCloudVision = 1
    case googleMLKit = 2
}

enum OCRPrimaryTranslationProvider: Int, CaseIterable {
    case appleTranslation = 0
    case googleCloudTranslation = 1
    case googleMLKit = 2
}

enum OCRProviderFallbackNotifier {
    static let notification = Notification.Name("OCRProviderDidFallbackToApple")
    static let messageKey = "message"
    static let siteKey = "site"
    static let galleryIDKey = "galleryID"

    @MainActor
    static func post(_ message: String, cacheKey: OCRCacheKey) {
        NotificationCenter.default.post(
            name: notification,
            object: nil,
            userInfo: [
                messageKey: message,
                siteKey: cacheKey.site.rawValue,
                galleryIDKey: cacheKey.galleryId
            ]
        )
    }
}
