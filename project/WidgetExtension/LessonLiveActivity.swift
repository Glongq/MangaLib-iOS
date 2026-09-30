import ActivityKit
import SwiftUI
import WidgetKit

@main
struct ClassPulseWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LessonActivityAttributes.self) { context in
            HStack(spacing: 16) {
                CountdownCircle(state: context.state, size: 58)
                VStack(alignment: .leading, spacing: 3) {
                    Text(context.attributes.lessonName)
                        .font(.headline)
                    Text("Next · \(context.attributes.nextLessonName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .activityBackgroundTint(.black)
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    HStack(spacing: 16) {
                        CountdownCircle(state: context.state, size: 58)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(context.attributes.lessonName)
                                .font(.headline)
                            Text("Next · \(context.attributes.nextLessonName)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                }
            } compactLeading: {
                EmptyView()
            } compactTrailing: {
                CountdownCircle(state: context.state, size: 42)
            } minimal: {
                CountdownCircle(state: context.state, size: 42)
            }
        }
    }
}

private struct CountdownCircle: View {
    let state: LessonActivityAttributes.ContentState
    let size: CGFloat

    var body: some View {
        Text(timerInterval: state.startedAt...state.endsAt,
             countsDown: true,
             showsHours: false)
            .font(.system(size: size < 50 ? 11 : 14, weight: .bold, design: .rounded))
            .monospacedDigit()
            .minimumScaleFactor(0.7)
            .lineLimit(1)
            .frame(width: size, height: size)
            .overlay {
                Circle().strokeBorder(.white.opacity(0.85), lineWidth: 1.5)
            }
            .accessibilityLabel("Time remaining in lesson")
    }
}
