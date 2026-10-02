import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct DriveInWidgets: WidgetBundle {
    var body: some Widget {
        DriveInLiveActivity()
    }
}

/// The parked-only status (and the video's play/pause) as a Live Activity. The small family
/// is what CarPlay Dashboard and Apple Watch show.
struct DriveInLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DriveInActivityAttributes.self) { context in
            DriveInActivityView(state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.75))
                .activitySystemActionForegroundColor(.orange)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: DriveInActivityView.symbol(for: context.state))
                        .foregroundStyle(DriveInActivityView.tint(for: context.state))
                        .font(.title2)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.drivingTitle)
                        .font(.headline)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    DriveInActivityButtons(state: context.state)
                }
            } compactLeading: {
                Image(systemName: DriveInActivityView.symbol(for: context.state))
                    .foregroundStyle(DriveInActivityView.tint(for: context.state))
            } compactTrailing: {
                Text(context.state.videoAllowed ? "Video" : "Audio")
                    .font(.caption2)
            } minimal: {
                Image(systemName: DriveInActivityView.symbol(for: context.state))
                    .foregroundStyle(DriveInActivityView.tint(for: context.state))
            }
        }
        .supplementalActivityFamilies([.small])
    }
}

struct DriveInActivityView: View {
    @Environment(\.activityFamily) private var family
    let state: DriveInActivityAttributes.ContentState

    var body: some View {
        switch family {
        case .small:
            compact
        default:
            regular
        }
    }

    /// CarPlay Dashboard / Apple Watch.
    private var compact: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(state.drivingTitle, systemImage: Self.symbol(for: state))
                .font(.headline)
                .foregroundStyle(Self.tint(for: state))
            Text(state.nowPlaying ?? state.detail)
                .font(.caption)
                .lineLimit(1)
            DriveInActivityButtons(state: state)
        }
        .padding(8)
    }

    /// Lock Screen and banner.
    private var regular: some View {
        HStack(spacing: 12) {
            Image(systemName: Self.symbol(for: state))
                .font(.largeTitle)
                .foregroundStyle(Self.tint(for: state))
            VStack(alignment: .leading, spacing: 2) {
                Text("DriveIn · \(state.drivingTitle)")
                    .font(.headline)
                Text(state.nowPlaying ?? state.detail)
                    .font(.subheadline)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            DriveInActivityButtons(state: state)
        }
        .padding()
    }

    static func symbol(for state: DriveInActivityAttributes.ContentState) -> String {
        if state.canConfirmParked { return "parkingsign.circle" }
        return state.videoAllowed ? "play.rectangle.fill" : "car.side.fill"
    }

    static func tint(for state: DriveInActivityAttributes.ContentState) -> Color {
        if state.canConfirmParked { return .orange }
        return state.videoAllowed ? .green : .red
    }
}

struct DriveInActivityButtons: View {
    let state: DriveInActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 8) {
            if state.canConfirmParked {
                Button(intent: ConfirmParkedIntent()) {
                    Label("I'm Parked", systemImage: "parkingsign")
                }
                .tint(.orange)
            }
            if state.nowPlaying != nil {
                Button(intent: TogglePlaybackIntent()) {
                    Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                }
                .tint(.white)
            }
        }
        .buttonStyle(.bordered)
        .font(.caption)
    }
}
