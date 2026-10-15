import Foundation

@main
struct ExternalRecommendationEngineTests {
    static func main() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let artist = ExternalRecommendationFeature(kind: .artist, value: "Example", siteID: "a")
        let tag = ExternalRecommendationFeature(kind: .tag, value: "shared_tag")
        let otherTag = ExternalRecommendationFeature(kind: .tag, value: "different")
        func document(_ id: Int, _ features: [ExternalRecommendationFeature], site: String = "a") -> ExternalRecommendationDocument {
            .init(siteID: site, galleryID: id, title: "Title \(id)", pageCount: 10, language: "English", features: features)
        }
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
        }

        let seed = document(1, [artist, tag])
        let matching = document(2, [artist, tag])
        let unrelated = document(3, [otherTag])
        var profile = ExternalRecommendationProfile()
        profile.setVote(.like, for: seed, at: now)
        var engine = ExternalRecommendationEngine(profile: profile, now: now)
        expect(engine.score(matching) > engine.score(unrelated), "A like must boost matching content")
        expect(engine.interests().contains(where: { $0.id == artist.id }), "Liked authors must generate retrieval interests")
        expect(!engine.isEligible(seed), "Already liked titles must not be recommended again")
        let copy = ExternalRecommendationDocument(siteID: "b", galleryID: 999, title: seed.title, pageCount: seed.pageCount, language: seed.language, features: seed.features)
        expect(!engine.isEligible(copy), "Known cross-site copies must not reappear after relaunch")
        let translation = ExternalRecommendationDocument(siteID: "b", galleryID: 998, title: seed.title, pageCount: seed.pageCount, language: "Russian", features: seed.features)
        expect(engine.isEligible(translation), "Different-language editions must remain distinct")

        profile.setVote(nil, for: seed, at: now)
        engine = ExternalRecommendationEngine(profile: profile, now: now)
        expect(abs(engine.affinity(for: artist)) < 0.0001, "Undo must remove the previous vote's contribution")
        profile.setVote(.like, for: seed, at: now)
        let once = ExternalRecommendationEngine(profile: profile, now: now).affinity(for: artist)
        profile.setVote(.like, for: seed, at: now)
        expect(profile.feedback.count == 1, "Repeated votes must not accumulate records")
        expect(ExternalRecommendationEngine(profile: profile, now: now).affinity(for: artist) == once, "Repeated assignment must not amplify a vote")

        profile.setVote(.dislike, for: seed, at: now)
        profile.recordExposure(seed, seconds: 120, pages: 10, at: now)
        profile.setBookmark(true, for: seed, at: now)
        engine = ExternalRecommendationEngine(profile: profile, now: now)
        expect(!engine.isEligible(seed), "Disliked titles must stay excluded")
        expect(engine.affinity(for: tag) < 0, "Explicit rejection must outweigh reading time and bookmarks")
        expect(engine.isEligible(matching), "One dislike must not ban the entire author")

        profile = ExternalRecommendationProfile()
        profile.setPreference(.hide, for: artist)
        engine = ExternalRecommendationEngine(profile: profile, now: now)
        expect(!engine.isEligible(matching), "Hidden authors must be excluded even from exploration")
        let namesake = ExternalRecommendationFeature(kind: .artist, value: "Example", siteID: "b")
        expect(engine.isEligible(document(4, [namesake], site: "b")), "Unverified namesakes on other sites must stay separate")
        let firstCreator = ExternalRecommendationFeature(kind: .artist, value: "Same name", siteID: "pixiv", entityID: "10")
        let secondCreator = ExternalRecommendationFeature(kind: .artist, value: "Same name", siteID: "pixiv", entityID: "11")
        expect(firstCreator.id != secondCreator.id, "Numeric creator identities must distinguish same-site namesakes")
        expect(ExternalRecommendationFeature(kind: .female, value: "shared tag").id != tag.id, "Tag namespaces must remain distinct")
        expect(ExternalRecommendationFeature(kind: .tag, value: " SHARED TAG ").id == tag.id, "Case and whitespace aliases should match")

        profile = ExternalRecommendationProfile()
        profile.recordExposure(seed, seconds: 0, pages: 0, at: now)
        profile.recordExposure(seed, seconds: .nan, pages: 1, at: now)
        expect(profile.feedback.isEmpty, "Unloaded pages must not create viewing signals")
        profile.recordExposure(seed, seconds: 10, pages: 3, at: now)
        engine = ExternalRecommendationEngine(profile: profile, now: now)
        expect(!engine.isEligible(seed), "Recent impressions must have a cooldown")
        expect(ExternalRecommendationEngine(profile: profile, now: now.addingTimeInterval(4 * 86_400)).isEligible(seed), "Cooldown must expire")
        expect(profile.feedback[seed.id]?.pagesRead == 3, "Reading progress must be tracked")
        profile.recordExposure(seed, seconds: 2, pages: 1, at: now)
        expect(profile.feedback[seed.id]?.pagesRead == 3, "Repeated impressions must not erase progress")
        let impressions = profile.feedback[seed.id]?.impressions
        profile.recordExposure(seed, seconds: 12, pages: 3, at: now, incrementImpression: false)
        expect(profile.feedback[seed.id]?.impressions == impressions, "Pausing for a sheet must not count a new impression")

        profile.setVote(.like, for: seed, at: now)
        let decoded = try JSONDecoder().decode(ExternalRecommendationProfile.self, from: JSONEncoder().encode(profile))
        expect(decoded.feedback[seed.id]?.vote == .like, "Votes must survive persistence")
        expect(decoded.feedback[seed.id]?.pagesRead == 3, "Progress must survive persistence")

        var candidates = (2...18).map { document($0, [artist, tag]) }
        let novel = document(99, [otherTag], site: "b")
        candidates.append(novel)
        engine = ExternalRecommendationEngine(profile: profile, now: now)
        let ranked = engine.ranked(candidates, after: [], offset: 0, limit: 10)
        expect(ranked.count == 10, "The queue should be filled")
        expect(Set(ranked.map(\.id)).count == ranked.count, "Queue entries must be unique")
        expect(ranked.prefix(5).contains(where: { $0.id == novel.id }), "Exploration must surface an unfamiliar interest")
        let duplicate = ExternalRecommendationDocument(siteID: "b", galleryID: 500, title: matching.title, pageCount: matching.pageCount, language: matching.language, features: matching.features)
        let deduplicated = engine.ranked([matching, duplicate], after: [], offset: 0, limit: 10)
        expect(deduplicated.count == 1, "Exact cross-site metadata duplicates must collapse")
        expect(engine.ranked([duplicate, matching], after: [], offset: 0, limit: 10).map(\.id) == deduplicated.map(\.id), "Duplicate selection must not depend on dictionary iteration order")
        expect(engine.ranked(candidates, after: [], offset: 0, limit: 10).map(\.id) == ranked.map(\.id), "Ranking must be reproducible within a session")

        profile.setPreference(.hide, for: tag)
        engine = ExternalRecommendationEngine(profile: profile, now: now)
        let filtered = engine.ranked(candidates, after: [], offset: 4, limit: 10)
        expect(filtered.allSatisfy { !$0.features.contains(where: { $0.id == tag.id }) }, "Exploration must respect hidden tags")
        profile.setPreference(nil, for: tag)
        expect(ExternalRecommendationEngine(profile: profile, now: now).isEligible(matching), "Removing a block must restore eligibility")

        for id in 100...105 { profile.recordExposure(document(id, [otherTag]), seconds: 5, pages: 1, at: now) }
        profile.prune(limit: 1)
        expect(profile.feedback.count == 1, "Profile storage must stay bounded")
        expect(profile.feedback[seed.id]?.vote == .like, "Pruning must prioritize explicit feedback over impressions")
        print("External recommendation engine: all checks passed")
    }
}
