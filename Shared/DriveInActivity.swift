import ActivityKit
import AppIntents
import Foundation

/// Live Activity shown on the Lock Screen, in the Dynamic Island and, from iOS 26, on the
/// CarPlay Dashboard. Apple's CarPlay guide: "Your app does not need to be a CarPlay app to
/// support widgets and Live Activities in CarPlay", so this works with a free Apple ID.
///
/// Compiled into both the app and the widget extension.
struct DriveInActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// "Driving", "Stopped", "Parked"…
        var drivingTitle: String
        /// One line under the title, e.g. "Video paused · sound only".
        var detail: String
        var videoAllowed: Bool
        var canConfirmParked: Bool
        /// Title of the video in DriveIn's player, if any.
        var nowPlaying: String?
        var isPlaying: Bool
    }
}

/// "I'm Parked" button on the Live Activity. Live Activity intents run in the app's process.
struct ConfirmParkedIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "I'm Parked"

    func perform() async throws -> some IntentResult {
        #if !DRIVEIN_WIDGET
        DispatchQueue.main.async {
            DrivingStateMonitor.shared.confirmParked()
        }
        #endif
        return .result()
    }
}

/// Play/pause button on the Live Activity.
struct TogglePlaybackIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Play or Pause"

    func perform() async throws -> some IntentResult {
        #if !DRIVEIN_WIDGET
        DispatchQueue.main.async {
            PlaybackController.shared.togglePlayPause()
        }
        #endif
        return .result()
    }
}
