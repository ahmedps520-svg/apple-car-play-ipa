import WebKit

/// Where a web view is displayed.
enum WebSurface {
    /// The iPhone browser (also driven remotely by the CarPlay template UI).
    case phone
    /// Rendered inside the CarPlay navigation window (workaround build only).
    case car
}

enum WebEnvironment {
    /// iOS 16 Safari had no Media Source Extensions. When MSE is hidden we also claim to be
    /// that browser, so sites that sniff the user agent pick the same plain-video fallback.
    static let legacyMobileUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 16_7_10 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1"

    static func userAgent(for surface: WebSurface) -> String? {
        let settings = AppSettings.shared
        if settings.prefersDesktopSites {
            // WebKit's desktop content mode supplies a Mac Safari user agent itself.
            return nil
        }
        return settings.carCompatibleVideo ? legacyMobileUserAgent : nil
    }

    static func makeConfiguration(surface: WebSurface) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
        configuration.allowsAirPlayForMediaPlayback = true
        configuration.allowsPictureInPictureMediaPlayback = surface == .phone
        // Autoplay is allowed; the parked-only gate suspends media instead.
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.preferences.isElementFullscreenEnabled = surface == .phone
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.defaultWebpagePreferences.preferredContentMode = AppSettings.shared.prefersDesktopSites ? .desktop : .mobile
        return configuration
    }

    static func installUserScripts(in controller: WKUserContentController, surface: WebSurface) {
        controller.removeAllUserScripts()
        if AppSettings.shared.carCompatibleVideo {
            controller.addUserScript(WKUserScript(source: WebScripts.hideMediaSourceExtensions,
                                                  injectionTime: .atDocumentStart,
                                                  forMainFrameOnly: false))
        }
        controller.addUserScript(WKUserScript(source: WebScripts.mediaObserver,
                                              injectionTime: .atDocumentEnd,
                                              forMainFrameOnly: false))
        if surface == .car {
            controller.addUserScript(WKUserScript(source: WebScripts.carInteraction,
                                                  injectionTime: .atDocumentEnd,
                                                  forMainFrameOnly: true))
        }
    }
}

/// `WKUserContentController` retains its message handlers; this breaks the cycle.
final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}
