import UIKit

final class PhoneSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = BrowserViewController(tab: BrowserTab.main)
        window.tintColor = .systemOrange
        self.window = window
        window.makeKeyAndVisible()

        if let url = connectionOptions.urlContexts.first?.url {
            open(url)
        }
        applyLaunchArguments()
    }

    /// Used by the CI smoke test: `-DriveInOpenURL <url>` and `-DriveInSimulation driving|stopped`
    /// arrive through the UserDefaults argument domain. They can't be set on a real install.
    private func applyLaunchArguments() {
        let defaults = UserDefaults.standard
        if let target = defaults.string(forKey: "DriveInOpenURL"), let page = AddressParser.url(from: target) {
            BrowserTab.main.load(page)
        }
        if let state = defaults.string(forKey: "DriveInSimulation").flatMap(DrivingSimulation.init(rawValue:)) {
            AppSettings.shared.drivingSimulation = state
        }
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        if let url = URLContexts.first?.url {
            open(url)
        }
    }

    private func open(_ url: URL) {
        switch url.scheme?.lowercased() {
        case "http", "https":
            BrowserTab.main.load(url)
        case "drivein":
            handleDriveInURL(url)
        default:
            break
        }
    }

    /// - `drivein://open?url=youtube.com` opens a page (handy for Shortcuts).
    /// - `drivein://simulate?state=driving|stopped|off` is a testing aid. It can only add
    ///   restrictions or return to the real sensors; it can never unlock video.
    private func handleDriveInURL(_ url: URL) {
        var query: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            if let value = item.value {
                query[item.name] = value
            }
        }
        switch url.host?.lowercased() {
        case "open":
            if let target = query["url"], let page = AddressParser.url(from: target) {
                BrowserTab.main.load(page)
            }
        case "simulate":
            if let state = query["state"].flatMap(DrivingSimulation.init(rawValue:)) {
                AppSettings.shared.drivingSimulation = state
            }
        default:
            break
        }
    }
}
