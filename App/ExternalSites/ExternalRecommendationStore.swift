import Foundation
import Combine

extension ExternalGalleryDetail {
    var recommendationDocument: ExternalRecommendationDocument {
        var features: [ExternalRecommendationFeature] = []
        for tag in tags {
            var value = tag.name
            var alias: String?
            if site == .pixiv, value.hasSuffix(")"), let split = value.range(of: " (", options: .backwards) {
                alias = String(value[split.upperBound...].dropLast())
                value = String(value[..<split.lowerBound])
            }
            if tag.female { features.append(.init(kind: .female, value: value, alias: alias)) }
            if tag.male { features.append(.init(kind: .male, value: value, alias: alias)) }
            if !tag.female && !tag.male { features.append(.init(kind: .tag, value: value, alias: alias)) }
        }
        let creatorID = site == .pixiv ? PixivProvider.feedArtistID(for: id).map(String.init) : nil
        features += artists.map { .init(kind: .artist, value: $0, siteID: site.rawValue, entityID: creatorID) }
        features += groups.map { .init(kind: .group, value: $0, siteID: site.rawValue) }
        features += characters.map { .init(kind: .character, value: $0) }
        features += series.map { .init(kind: .series, value: $0) }
        if !type.isEmpty { features.append(.init(kind: .format, value: type)) }
        var seen = Set<String>()
        features = features.filter { !ExternalRecommendationFeature.normalize($0.value).isEmpty && seen.insert($0.retrievalID).inserted }
        let date = ExternalRecommendationDate.parse(posted)
        return ExternalRecommendationDocument(
            siteID: site.rawValue, galleryID: id, title: title, pageCount: pages.count,
            language: language, features: features, publishedAt: date,
            contentKind: video == nil ? .manga : .video
        )
    }
}

/// On-device preferences shared by every external feed; no account or background worker is needed.
@MainActor
final class ExternalRecommendationStore: ObservableObject {
    static let shared = ExternalRecommendationStore()
    @Published private(set) var revision = 0
    private(set) var profile: ExternalRecommendationProfile
    let learning: ExternalRecommendationLearningStore
    private let defaults: UserDefaults
    private static let storageKey = "external_recommendation_profile_v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        learning = ExternalRecommendationLearningStore(defaults: defaults)
        profile = defaults.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode(ExternalRecommendationProfile.self, from: $0) }
            ?? ExternalRecommendationProfile()
        let mergedTags = profile.mergeSharedTagPreferences()
        let migratedLikes = profile.migrateLikeDates()
        if mergedTags || migratedLikes, let data = try? JSONEncoder().encode(profile) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    func vote(for document: ExternalRecommendationDocument) -> ExternalRecommendationVote? {
        profile.feedback[document.id]?.vote
    }

    func toggleVote(_ vote: ExternalRecommendationVote, for document: ExternalRecommendationDocument,
                    detail: ExternalGalleryDetail? = nil, resolveKey: String? = nil) {
        let newVote = self.vote(for: document) == vote ? nil : vote
        profile.setVote(newVote, for: document, at: Date())
        if newVote != nil { learning.qualifyExplicit(document) }
        if newVote == .like {
            ExternalHistoryStore.shared.record(document: document, detail: detail, resolveKey: resolveKey)
        }
        save()
        if newVote == .like, document.siteID == ExternalSite.rule34.rawValue {
            // Website failures never undo local feedback or interrupt the feed.
            Task { try? await Rule34Provider().upvote(id: document.galleryID) }
        }
    }

    func setBookmark(_ saved: Bool, for document: ExternalRecommendationDocument) {
        guard profile.feedback[document.id]?.bookmarked != saved else { return }
        profile.setBookmark(saved, for: document, at: Date())
        if saved { learning.qualifyExplicit(document) }
        save()
    }

    func recordExposure(_ document: ExternalRecommendationDocument, seconds: Double, pages: Int, incrementImpression: Bool = true, watchedFraction: Double? = nil) {
        guard pages >= 0, seconds >= 0.6 else { return }
        profile.recordExposure(document, seconds: seconds, pages: pages, at: Date(), incrementImpression: incrementImpression, watchedFraction: watchedFraction)
        save()
    }

    func recordPresentation(_ exposure: RecommendationExposure) {
        let fact = profile.feedback[exposure.document.id]
        learning.record(exposure, explicit: fact?.vote != nil || fact?.bookmarked == true)
    }

    func preference(for feature: ExternalRecommendationFeature) -> ExternalRecommendationPreference.Value? {
        profile.preferences[feature.id]?.value
    }

    func setPreference(_ value: ExternalRecommendationPreference.Value?, for feature: ExternalRecommendationFeature) {
        profile.setPreference(value, for: feature)
        save()
    }

    func synchronizeBookmarks(_ bookmarks: [ExternalBookmark]) {
        let saved = Set(bookmarks.map(\.id))
        var changed = false
        for (id, record) in profile.feedback where record.bookmarked != saved.contains(id) {
            profile.setBookmark(saved.contains(id), for: record.document, at: Date())
            if saved.contains(id) { learning.qualifyExplicit(record.document) }
            changed = true
        }
        if changed { save() }
    }

    private func save() {
        profile.prune()
        if let data = try? JSONEncoder().encode(profile) { defaults.set(data, forKey: Self.storageKey) }
        revision &+= 1
    }
}
