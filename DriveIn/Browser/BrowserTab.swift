import UIKit
import WebKit

/// One browser tab: a `WKWebView` plus the media it found on the current page.
final class BrowserTab: NSObject {
    /// The tab shown on the iPhone. The CarPlay template UI drives this same tab, so
    /// "browsing from the car" and "browsing on the phone" are one session.
    static let main = BrowserTab(surface: .phone)

    let surface: WebSurface
    private(set) var webView: WKWebView!
    /// Media found in all frames of the current page, top frame first.
    private(set) var pageMedia: [MediaItem] = []
    private(set) var isShowingStartPage = true

    private var frameMedia: [String: [MediaItem]] = [:]
    private var observations: [NSKeyValueObservation] = []
    private var mediaWaiters: [UUID: (MediaItem?) -> Void] = [:]
    private var loadWaiters: [UUID: (Bool) -> Void] = [:]
    private var scriptSignature = ""
    private var mediaSuspended = false
    /// Set when DriveIn starts a navigation; `isLoading` can still be false at that moment.
    private var navigationPending = false

    init(surface: WebSurface) {
        self.surface = surface
        super.init()
        webView = makeWebView()
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged), name: .settingsDidChange, object: nil)
    }

    // MARK: - Public

    /// The page URL, or nil while the built-in start page is showing.
    var currentURL: URL? {
        guard !isShowingStartPage, let url = webView.url, url.scheme != "about" else { return nil }
        return url
    }

    var title: String {
        if isShowingStartPage { return "Start" }
        let title = webView.title ?? ""
        return title.isEmpty ? AddressParser.displayString(for: webView.url) : title
    }

    var playableMedia: [MediaItem] {
        pageMedia.filter { $0.isNativelyPlayable }
    }

    func load(_ url: URL) {
        isShowingStartPage = false
        clearPageMedia()
        navigationPending = true
        webView.load(URLRequest(url: url))
        notifyChange()
    }

    /// Loads typed text: a URL if it looks like one, otherwise a web search.
    @discardableResult
    func load(input: String) -> Bool {
        guard let url = AddressParser.url(from: input) else { return false }
        load(url)
        return true
    }

    func showStartPage() {
        isShowingStartPage = true
        clearPageMedia()
        navigationPending = true
        webView.loadHTMLString(StartPage.html(compact: surface == .car), baseURL: nil)
        notifyChange()
    }

    func goBack() {
        if webView.canGoBack {
            navigationPending = true
            webView.goBack()
        } else if !isShowingStartPage {
            showStartPage()
        }
    }

    func goForward() {
        if webView.canGoForward {
            navigationPending = true
            webView.goForward()
        }
    }

    func reload() {
        if isShowingStartPage {
            showStartPage()
        } else {
            navigationPending = true
            webView.reload()
        }
    }

    func stopLoading() {
        navigationPending = false
        webView.stopLoading()
    }

    /// Engine-level switch: suspended media can't be resumed by the page.
    func setMediaSuspended(_ suspended: Bool) {
        guard suspended != mediaSuspended else { return }
        mediaSuspended = suspended
        webView.setAllMediaPlaybackSuspended(suspended, completionHandler: nil)
    }

    func pauseAllMedia() {
        webView.pauseAllMediaPlayback(completionHandler: nil)
    }

    /// Calls back once the current navigation finished (true) or failed/timed out (false).
    func whenLoaded(timeout: TimeInterval, completion: @escaping (Bool) -> Void) {
        if !webView.isLoading && !navigationPending {
            DispatchQueue.main.async { completion(true) }
            return
        }
        let id = UUID()
        loadWaiters[id] = completion
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            if let waiter = self?.loadWaiters.removeValue(forKey: id) {
                waiter(false)
            }
        }
    }

    /// Calls back with the first stream DriveIn's player can play, or nil after `timeout`.
    func waitForPlayableMedia(timeout: TimeInterval, completion: @escaping (MediaItem?) -> Void) {
        if let item = preferredPlayableItem() {
            completion(item)
            return
        }
        let id = UUID()
        mediaWaiters[id] = completion
        webView.evaluateJavaScript(WebScripts.rescanMedia, completionHandler: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            if let waiter = self?.mediaWaiters.removeValue(forKey: id) {
                waiter(nil)
            }
        }
    }

    func rescanMedia() {
        webView.evaluateJavaScript(WebScripts.rescanMedia, completionHandler: nil)
    }

    /// Links on the current page, video-looking ones first.
    func extractLinks(completion: @escaping (_ pageTitle: String, _ links: [PageLink]) -> Void) {
        webView.evaluateJavaScript(WebScripts.linkExtractor) { result, _ in
            guard let json = result as? String,
                  let data = json.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any]
            else {
                completion("", [])
                return
            }
            let pageTitle = object["title"] as? String ?? ""
            var links: [PageLink] = []
            for entry in object["links"] as? [[String: Any]] ?? [] {
                guard let urlString = entry["url"] as? String, let url = URL(string: urlString) else { continue }
                let thumbnail = (entry["thumb"] as? String).flatMap(URL.init(string:)) ?? MediaItem.youTubeThumbnailURL(for: url)
                let title = (entry["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? AddressParser.displayString(for: url)
                links.append(PageLink(title: title, url: url, thumbnailURL: thumbnail, isLikelyVideo: PageLink.isLikelyVideoPage(url)))
            }
            let videos = links.filter { $0.isLikelyVideo }
            let others = links.filter { !$0.isLikelyVideo }
            completion(pageTitle, videos + others)
        }
    }

    /// Runs one of the CarPlay-window helpers (`clickAt`, `typeText`, …).
    func callCarHelper(_ function: String, _ arguments: [Any], completion: ((Any?) -> Void)? = nil) {
        webView.evaluateJavaScript(WebScripts.carCall(function, arguments)) { result, _ in
            completion?(result)
        }
    }

    // MARK: - Setup

    private func makeWebView() -> WKWebView {
        let configuration = WebEnvironment.makeConfiguration(surface: surface)
        let controller = configuration.userContentController
        WebEnvironment.installUserScripts(in: controller, surface: surface)
        controller.add(WeakScriptMessageHandler(self), name: WebScripts.mediaHandlerName)
        scriptSignature = currentScriptSignature()

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = surface == .phone
        webView.allowsLinkPreview = surface == .phone
        webView.customUserAgent = WebEnvironment.userAgent(for: surface)
        webView.isInspectable = true
        webView.backgroundColor = .systemBackground

        observations = [
            webView.observe(\.title, options: [.new]) { [weak self] _, _ in self?.notifyChange() },
            webView.observe(\.url, options: [.new]) { [weak self] _, _ in self?.urlChanged() },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] _, _ in self?.notifyChange() },
            webView.observe(\.isLoading, options: [.new]) { [weak self] _, _ in self?.notifyChange() },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in self?.notifyChange() },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in self?.notifyChange() },
        ]
        return webView
    }

    private func currentScriptSignature() -> String {
        let settings = AppSettings.shared
        return "\(settings.carCompatibleVideo)|\(settings.prefersDesktopSites)"
    }

    @objc private func settingsChanged(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let signature = self.currentScriptSignature()
            guard signature != self.scriptSignature else { return }
            self.scriptSignature = signature
            WebEnvironment.installUserScripts(in: self.webView.configuration.userContentController, surface: self.surface)
            self.webView.customUserAgent = WebEnvironment.userAgent(for: self.surface)
            if !self.isShowingStartPage {
                self.webView.reload()
            }
        }
    }

    private func notifyChange() {
        NotificationCenter.default.post(name: .browserTabDidChange, object: self)
    }

    private func urlChanged() {
        // Single-page sites (YouTube…) change the URL without a navigation. Ask the page
        // to report its media again; the top-frame entry is replaced when it does.
        rescanMedia()
        notifyChange()
    }

    // MARK: - Media

    private func clearPageMedia() {
        frameMedia.removeAll()
        rebuildPageMedia()
    }

    private func rebuildPageMedia() {
        var seen = Set<String>()
        var merged: [MediaItem] = []
        let keys = frameMedia.keys.sorted { lhs, rhs in
            lhs == "top" ? true : (rhs == "top" ? false : lhs < rhs)
        }
        for key in keys {
            for item in frameMedia[key] ?? [] where !seen.contains(item.id) {
                seen.insert(item.id)
                merged.append(item)
            }
        }
        pageMedia = merged
        MediaCatalog.shared.record(merged)

        if let item = preferredPlayableItem(), !mediaWaiters.isEmpty {
            let waiters = mediaWaiters.values
            mediaWaiters.removeAll()
            waiters.forEach { $0(item) }
        }
        notifyChange()
    }

    private func preferredPlayableItem() -> MediaItem? {
        let playable = playableMedia
        return playable.first { $0.kind == .hls } ?? playable.first
    }

    private func handleMediaMessage(_ body: [String: Any], isMainFrame: Bool) {
        let isTop = body["isTop"] as? Bool ?? isMainFrame
        let frameURLString = body["frameURL"] as? String ?? UUID().uuidString
        let pageURL = webView.url
        let ogTitle = (body["ogTitle"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let pageTitle = ogTitle ?? (body["pageTitle"] as? String) ?? ""
        let ogImage = (body["ogImage"] as? String).flatMap(URL.init(string:))
        let fallbackPoster = ogImage ?? pageURL.flatMap(MediaItem.youTubeThumbnailURL(for:))

        var items: [MediaItem] = []
        let rawMedia = body["media"] as? [[String: Any]] ?? []
        for (index, raw) in rawMedia.enumerated() {
            guard let src = raw["src"] as? String, let url = URL(string: src) else { continue }
            let kind = MediaItem.classify(url)
            let duration = (raw["duration"] as? NSNumber)?.doubleValue
            let poster = (raw["poster"] as? String).flatMap(URL.init(string:)) ?? fallbackPoster
            let rawTitle = (raw["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? pageTitle
            let streamURL = (kind == .hls || kind == .progressive) ? url : nil
            items.append(MediaItem(id: streamURL?.absoluteString ?? "\(frameURLString)#\(index)",
                                   title: BrowserTab.cleanTitle(rawTitle, fallbackURL: pageURL),
                                   pageURL: pageURL,
                                   streamURL: streamURL,
                                   posterURL: poster,
                                   duration: (duration ?? 0) > 0 ? duration : nil,
                                   isLive: duration == -1,
                                   kind: kind,
                                   discovered: Date()))
        }
        if let ogVideo = (body["ogVideo"] as? String).flatMap(URL.init(string:)) {
            let kind = MediaItem.classify(ogVideo)
            if (kind == .hls || kind == .progressive), !items.contains(where: { $0.streamURL == ogVideo }) {
                items.append(MediaItem(id: ogVideo.absoluteString,
                                       title: BrowserTab.cleanTitle(pageTitle, fallbackURL: pageURL),
                                       pageURL: pageURL,
                                       streamURL: ogVideo,
                                       posterURL: fallbackPoster,
                                       duration: nil,
                                       isLive: false,
                                       kind: kind,
                                       discovered: Date()))
            }
        }

        frameMedia[isTop ? "top" : frameURLString] = items
        rebuildPageMedia()
    }

    static func cleanTitle(_ title: String, fallbackURL: URL?) -> String {
        var cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in [" - YouTube", " | Twitch", " on Vimeo", " - Dailymotion"] where cleaned.hasSuffix(suffix) {
            cleaned = String(cleaned.dropLast(suffix.count))
        }
        if cleaned.isEmpty {
            cleaned = AddressParser.displayString(for: fallbackURL)
        }
        return cleaned.isEmpty ? "Video" : cleaned
    }

    private func finishLoadWaiters(success: Bool) {
        let waiters = loadWaiters.values
        loadWaiters.removeAll()
        waiters.forEach { $0(success) }
    }
}

// MARK: - WKScriptMessageHandler

extension BrowserTab: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == WebScripts.mediaHandlerName, let body = message.body as? [String: Any] else { return }
        handleMediaMessage(body, isMainFrame: message.frameInfo.isMainFrame)
    }
}

// MARK: - WKNavigationDelegate

extension BrowserTab: WKNavigationDelegate {
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 preferences: WKWebpagePreferences,
                 decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        preferences.preferredContentMode = AppSettings.shared.prefersDesktopSites ? .desktop : .mobile
        guard let url = navigationAction.request.url, let scheme = url.scheme?.lowercased() else {
            decisionHandler(.allow, preferences)
            return
        }
        switch scheme {
        case "http", "https", "about", "data", "blob":
            decisionHandler(.allow, preferences)
        case "tel", "mailto", "sms", "facetime":
            if surface == .phone {
                UIApplication.shared.open(url)
            }
            decisionHandler(.cancel, preferences)
        default:
            // App links such as youtube:// would leave DriveIn; stay in the browser.
            decisionHandler(.cancel, preferences)
        }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        isShowingStartPage = webView.url == nil || webView.url?.scheme == "about"
        clearPageMedia()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let url = currentURL {
            LibraryStore.shared.recordVisit(title: webView.title ?? "", url: url)
        }
        navigationPending = false
        finishLoadWaiters(success: true)
        rescanMedia()
        notifyChange()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleFailure(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleFailure(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    private func handleFailure(_ error: Error) {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            // Usually replaced by a newer navigation, whose result the waiters get.
            return
        }
        navigationPending = false
        finishLoadWaiters(success: false)
        notifyChange()
    }
}

// MARK: - WKUIDelegate

extension BrowserTab: WKUIDelegate {
    /// `target="_blank"` links and `window.open` load in the same tab.
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
            load(url)
        }
        return nil
    }
}
