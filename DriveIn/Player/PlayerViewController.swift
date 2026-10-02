import AVKit
import UIKit

/// Full-screen player on the iPhone. AVPlayerViewController supplies the AirPlay button,
/// which is how video reaches a car that supports AirPlay "video in car" (iOS 26+).
final class PlayerViewController: AVPlayerViewController {
    private let gateOverlay = ParkedGateOverlayView(style: .phone)

    override func viewDidLoad() {
        super.viewDidLoad()
        player = PlaybackController.shared.player
        // DriveIn publishes Now Playing info itself (for CarPlay's Now Playing screen).
        updatesNowPlayingInfoCenter = false
        allowsPictureInPicturePlayback = false

        if let overlayHost = contentOverlayView {
            gateOverlay.translatesAutoresizingMaskIntoConstraints = false
            overlayHost.addSubview(gateOverlay)
            NSLayoutConstraint.activate([
                gateOverlay.leadingAnchor.constraint(equalTo: overlayHost.leadingAnchor),
                gateOverlay.trailingAnchor.constraint(equalTo: overlayHost.trailingAnchor),
                gateOverlay.topAnchor.constraint(equalTo: overlayHost.topAnchor),
                gateOverlay.bottomAnchor.constraint(equalTo: overlayHost.bottomAnchor),
            ])
        }
        gateOverlay.onConfirmParked = {
            DrivingStateMonitor.shared.confirmParked()
        }
        gateOverlay.onOpenSettings = {
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        }

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(refresh), name: .drivingStateDidChange, object: nil)
        center.addObserver(self, selector: #selector(refresh), name: .playbackStateDidChange, object: nil)
        refresh()
    }

    @objc private func refresh() {
        let monitor = DrivingStateMonitor.shared
        let blocked = PlaybackController.shared.isVideoBlocked
        gateOverlay.isHidden = !blocked
        // The overlay sits under the transport controls, so pause/AirPlay stay usable.
        gateOverlay.isUserInteractionEnabled = blocked
        gateOverlay.configure(state: monitor.state,
                              canConfirm: monitor.canConfirmParked,
                              secondsRemaining: monitor.secondsUntilParkedAllowed,
                              audioContinues: AppSettings.shared.audioContinuesWhileDriving,
                              missingPermissions: monitor.missingPermissions)
        // Picture in Picture would escape the gate; only offer it when no car is involved.
        allowsPictureInPicturePlayback = monitor.state == .notConnected
    }
}
