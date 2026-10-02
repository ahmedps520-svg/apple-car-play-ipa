import CarPlay
import UIKit

/// CarPlay only creates this scene when the installed app is signed with a CarPlay
/// entitlement. Which method CarPlay calls depends on that entitlement:
/// - video/audio apps (official, iOS 27): `didConnect:` → template UI.
/// - navigation apps: `didConnect:to:` with a window → web view on the car screen (workaround).
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var templateBrowser: CarPlayTemplateBrowser?
    private var windowBrowser: CarPlayWindowBrowser?
    private var sessionMonitor: CarPlaySessionMonitor?

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        guard windowBrowser == nil, templateBrowser == nil else { return }
        let monitor = startSession(mode: .templates)
        let browser = CarPlayTemplateBrowser(interfaceController: interfaceController, session: monitor)
        templateBrowser = browser
        browser.start()
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController,
                                  to window: CPWindow) {
        guard windowBrowser == nil else { return }
        templateBrowser?.stop()
        templateBrowser = nil
        let monitor = startSession(mode: .window)
        let browser = CarPlayWindowBrowser(interfaceController: interfaceController, window: window, session: monitor)
        windowBrowser = browser
        browser.start()
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        endSession()
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnect interfaceController: CPInterfaceController,
                                  from window: CPWindow) {
        endSession()
    }

    private func startSession(mode: CarPlaySessionState.Mode) -> CarPlaySessionMonitor {
        let monitor = sessionMonitor ?? CarPlaySessionMonitor()
        sessionMonitor = monitor
        monitor.mode = mode
        monitor.publish()
        DrivingStateMonitor.shared.setCarPlaySceneConnected(true)
        return monitor
    }

    private func endSession() {
        templateBrowser?.stop()
        templateBrowser = nil
        windowBrowser?.stop()
        windowBrowser = nil
        sessionMonitor = nil
        CarPlaySessionState.shared.reset()
        DrivingStateMonitor.shared.setCarPlaySceneConnected(false)
    }
}

/// Wraps `CPSessionConfiguration`: keyboard/list limits (the car's own "driving" signal)
/// and, on iOS 26.4+, whether the car supports video playback at all.
final class CarPlaySessionMonitor: NSObject, CPSessionConfigurationDelegate {
    var mode: CarPlaySessionState.Mode = .none
    var onChange: (() -> Void)?
    private var configuration: CPSessionConfiguration?

    override init() {
        super.init()
        configuration = CPSessionConfiguration(delegate: self)
    }

    var limitsKeyboard: Bool {
        configuration?.limitedUserInterfaces.contains(.keyboard) ?? false
    }

    var limitsLists: Bool {
        configuration?.limitedUserInterfaces.contains(.lists) ?? false
    }

    /// `nil` before iOS 26.4, where the property doesn't exist.
    var supportsVideoPlayback: Bool? {
        guard let configuration = configuration else { return nil }
        if #available(iOS 26.4, *) {
            return configuration.supportsVideoPlayback
        }
        return nil
    }

    func publish() {
        DrivingStateMonitor.shared.setVehicleLimitsKeyboard(configuration == nil ? nil : limitsKeyboard)
        CarPlaySessionState.shared.update(mode: mode,
                                          supportsVideoPlayback: supportsVideoPlayback,
                                          limitsKeyboard: configuration == nil ? nil : limitsKeyboard,
                                          limitsLists: configuration == nil ? nil : limitsLists)
    }

    func sessionConfiguration(_ sessionConfiguration: CPSessionConfiguration,
                              limitedUserInterfacesChanged limitedUserInterfaces: CPLimitableUserInterface) {
        publish()
        onChange?()
    }

    func sessionConfiguration(_ sessionConfiguration: CPSessionConfiguration,
                              contentStyleChanged contentStyle: CPContentStyle) {
        onChange?()
    }
}
