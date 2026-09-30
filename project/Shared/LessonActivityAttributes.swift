import ActivityKit
import Foundation

struct LessonActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        let startedAt: Date
        let endsAt: Date
    }

    let lessonName: String
    let nextLessonName: String
}
