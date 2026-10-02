import ActivityKit
import Foundation
import os
import UIKit

/// Shows DriveIn's parked state (and the current video) as a Live Activity while the iPhone is
/// connected to CarPlay. iOS 26+ puts Live Activities on the CarPlay Dashboard, so this is
/// DriveIn's one surface on the car screen that needs no CarPlay entitlement. Its "I'm Parked"
/// and play/pause buttons work on the Lock Screen; Apple doesn't document whether CarPlay
/// passes taps to Live Activities.
///
/// iOS only lets an app *start* a Live Activity while it is in the foreground, so it starts when
/// DriveIn is open on the iPhone while connected; updates and ending work from the background.
final class LiveActivityController: NSObject {
    static let shared = LiveActivityController()

    private var activity: Activity<DriveInActivityAttributes>?
    private var lastState: DriveInActivityAttributes.ContentState?
    private var started = false
    private var loggedDisabled = false
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "DriveIn", category: "LiveActivity")

    private override init() {
        super.init()
    }

    func start() {
        guard !started else { return }
        started = true
        // Pick up an activity left over from a previous launch.
        activity = Activity<DriveInActivityAttributes>.activities.first
        let center = NotificationCenter.default
        for name in [Notification.Name.drivingStateDidChange, .playbackStateDidChange, UIApplication.didBecomeActiveNotification] {
            center.addObserver(self, selector: #selector(refresh), name: name, object: nil)
        }
        refresh()
    }

    @objc private func refresh() {
        DispatchQueue.main.async { [weak self] in
            self?.sync()
        }
    }

    private func sync() {
        let monitor = DrivingStateMonitor.shared
        guard monitor.isConnected else {
            end()
            return
        }
        let state = currentContentState()
        if let activity = activity, activity.activityState == .active || activity.activityState == .stale {
            guard state != lastState else { return }
            lastState = state
            let content = ActivityContent(state: state, staleDate: nil)
            Task {
                await activity.update(content)
            }
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            if !loggedDisabled {
                loggedDisabled = true
                log.notice("Live Activities are turned off for DriveIn")
            }
            return
        }
        guard UIApplication.shared.applicationState == .active else { return }
        do {
            let activity = try Activity.request(attributes: DriveInActivityAttributes(),
                                                content: ActivityContent(state: state, staleDate: nil),
                                                pushType: nil)
            self.activity = activity
            lastState = state
            log.notice("Started Live Activity \(activity.id, privacy: .public): \(state.drivingTitle, privacy: .public)")
        } catch {
            activity = nil
            log.error("Couldn't start the Live Activity: \(String(describing: error), privacy: .public)")
        }
    }

    private func end() {
        guard let activity = activity else { return }
        self.activity = nil
        lastState = nil
        log.notice("Ending Live Activity \(activity.id, privacy: .public)")
        Task {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    private func currentContentState() -> DriveInActivityAttributes.ContentState {
        let monitor = DrivingStateMonitor.shared
        let playback = PlaybackController.shared
        let audioContinues = AppSettings.shared.audioContinuesWhileDriving
        let detail: String
        switch monitor.state {
        case .parked, .notConnected:
            detail = "Video allowed"
        case .stopped:
            detail = monitor.canConfirmParked ? "Tap I'm Parked to watch" : "Waiting for the car to stand still"
        case .moving:
            detail = audioContinues ? "Video paused · sound only" : "Video paused"
        case .unknown:
            detail = "Parked status unknown · video off"
        }
        return DriveInActivityAttributes.ContentState(
            drivingTitle: monitor.state.title,
            detail: detail,
            videoAllowed: monitor.state.allowsVideo,
            canConfirmParked: monitor.canConfirmParked,
            nowPlaying: playback.currentItem?.title,
            isPlaying: playback.currentItem != nil && playback.isPlaying
        )
    }
}
