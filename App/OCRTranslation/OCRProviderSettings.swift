import Foundation

enum OCRRecognitionProvider: Int, CaseIterable {
    case appleVision = 0
    case googleCloudVision = 1
}

enum OCRPrimaryTranslationProvider: Int, CaseIterable {
    case appleTranslation = 0
    case googleCloudTranslation = 1
}

enum OCRGoogleCloudCredentials {
    static let keychain = KeychainHelper(service: "com.glongq.MangaLib.ocrTranslation")
    static let apiKeyAccount = "googleCloudAPIKey"

    static var apiKey: String? {
        guard let value = keychain.readString(apiKeyAccount), !value.isEmpty else { return nil }
        return value
    }
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
