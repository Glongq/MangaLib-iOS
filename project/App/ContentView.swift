import ActivityKit
import SwiftUI

struct ContentView: View {
    @State private var activity: Activity<LessonActivityAttributes>?
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("CLASS PULSE")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .tracking(3)
                .foregroundStyle(.secondary)

            Spacer()

            if let activity {
                Text("Current lesson")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(activity.attributes.lessonName)
                    .font(.system(size: 36, weight: .semibold, design: .rounded))
                Text(timerInterval: activity.content.state.startedAt...activity.content.state.endsAt,
                     countsDown: true,
                     showsHours: false)
                    .font(.system(size: 64, weight: .medium, design: .rounded))
                    .monospacedDigit()
                Text("Next · \(activity.attributes.nextLessonName)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text("One lesson. One glance.")
                    .font(.system(size: 36, weight: .semibold, design: .rounded))
                Text("Start a short sample lesson to check the Live Activity on your iPhone.")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            Button(activity == nil ? "Start 10-minute test" : "End test") {
                if activity == nil {
                    startTest()
                } else {
                    Task { await endTest() }
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.white)
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
        .foregroundStyle(.white)
        .onAppear {
            activity = Activity<LessonActivityAttributes>.activities.first
        }
    }

    private func startTest() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            errorMessage = "Enable Live Activities for this app in Settings."
            return
        }

        let start = Date()
        let state = LessonActivityAttributes.ContentState(
            startedAt: start,
            endsAt: start.addingTimeInterval(10 * 60)
        )
        let attributes = LessonActivityAttributes(
            lessonName: "Sample lesson",
            nextLessonName: "Next lesson"
        )

        do {
            activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: state.endsAt),
                pushType: nil
            )
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func endTest() async {
        guard let activity else { return }
        await activity.end(nil, dismissalPolicy: .immediate)
        self.activity = nil
    }
}
