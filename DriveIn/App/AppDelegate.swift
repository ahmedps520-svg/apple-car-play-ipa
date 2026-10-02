import AVFoundation
import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    // Scene classes and delegates come from UIApplicationSceneManifest in Config/Info.plist:
    // PhoneSceneDelegate for the iPhone, CarPlaySceneDelegate for CarPlay.

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Playback category lets video keep its sound with the silent switch on and while
        // CarPlay is in use. Not activated here, so other apps' audio isn't interrupted.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [])
        DrivingStateMonitor.shared.start()
        _ = PlaybackController.shared
        LiveActivityController.shared.start()
        return true
    }
}
