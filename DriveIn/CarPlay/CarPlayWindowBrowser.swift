import CarPlay
import UIKit

/// WORKAROUND path (navigation entitlement `com.apple.developer.carplay-maps`).
///
/// Navigation apps are the only CarPlay category that gets a window to draw in. DriveIn puts a
/// WKWebView there, which is the closest thing to "a browser on the CarPlay display" — and it's
/// exactly what the CarPlay guidelines forbid ("The base view must be used exclusively to draw a
/// map"), so Apple won't grant the entitlement for it. Controls:
/// - Drag on the screen: scroll (map pan gesture callbacks).
/// - Double-tap on the screen: click there (zoom gesture callback with a center point, iOS 26+).
/// - Pinch: page zoom. Map buttons: click at cursor, play/pause, theater, arrow-key cursor mode.
/// - Nav bar: back, reload, address/search keyboard, bookmarks.
final class CarPlayWindowBrowser: NSObject {
    private enum KeyboardMode {
        case address
        case typeIntoPage
    }

    private let interfaceController: CPInterfaceController
    private let window: CPWindow
    private let session: CarPlaySessionMonitor
    private let webController = CarWebViewController()
    private let mapTemplate = CPMapTemplate()
    private var observers: [NSObjectProtocol] = []
    private var keyboardMode: KeyboardMode = .address
    private var searchText = ""
    private var theaterOn = false
    private var gateKey = ""
    private var askedAboutParking = false

    // Zoom-gesture bookkeeping: a short gesture with almost no updates is a double tap.
    private var zoomStart: Date?
    private var zoomUpdates = 0
    private var zoomCenter: CGPoint?
    private var zoomBase: CGFloat = 1
    private var searchButton: CPBarButton?
    private var sitesButton: CPBarButton?

    init(interfaceController: CPInterfaceController, window: CPWindow, session: CarPlaySessionMonitor) {
        self.interfaceController = interfaceController
        self.window = window
        self.session = session
        super.init()
    }

    func start() {
        window.rootViewController = webController
        webController.onEditableFieldFocused = { [weak self] _ in
            self?.presentKeyboard(.typeIntoPage)
        }
        configureTemplate()
        interfaceController.setRootTemplate(mapTemplate, animated: false, completion: nil)

        let center = NotificationCenter.default
        for name in [Notification.Name.drivingStateDidChange, .carPlaySessionDidChange, .settingsDidChange] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.updateGate()
            })
        }
        webController.loadInitialPage()
        updateGate()
    }

    func stop() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        webController.tab.pauseAllMedia()
        window.rootViewController = nil
    }

    // MARK: - Template

    private func configureTemplate() {
        mapTemplate.mapDelegate = self
        mapTemplate.automaticallyHidesNavigationBar = false
        mapTemplate.hidesButtonsWithNavigationBar = false

        let back = CPBarButton(image: CarPlayImages.symbol("chevron.backward")) { [weak self] _ in
            self?.webController.tab.goBack()
        }
        let reload = CPBarButton(image: CarPlayImages.symbol("arrow.clockwise")) { [weak self] _ in
            self?.webController.tab.reload()
        }
        let search = CPBarButton(image: CarPlayImages.symbol("magnifyingglass")) { [weak self] _ in
            self?.presentKeyboard(.address)
        }
        let sites = CPBarButton(image: CarPlayImages.symbol("star")) { [weak self] _ in
            self?.presentSites()
        }
        searchButton = search
        sitesButton = sites
        mapTemplate.leadingNavigationBarButtons = [back, reload]
        mapTemplate.trailingNavigationBarButtons = [search, sites]
    }

    private func browsingMapButtons() -> [CPMapButton] {
        [
            mapButton("cursorarrow.click.2") { $0.webController.click() },
            mapButton("playpause.fill") { $0.webController.togglePlayPause() },
            mapButton("arrow.up.left.and.arrow.down.right") { browser in
                browser.theaterOn.toggle()
                browser.webController.setTheater(browser.theaterOn)
            },
            mapButton("arrow.up.and.down.and.arrow.left.and.right") { $0.mapTemplate.showPanningInterface(animated: true) },
        ]
    }

    private func mapButton(_ symbol: String, action: @escaping (CarPlayWindowBrowser) -> Void) -> CPMapButton {
        let button = CPMapButton { [weak self] _ in
            guard let self = self else { return }
            action(self)
        }
        button.image = CarPlayImages.symbol(symbol, pointSize: 22)
        return button
    }

    // MARK: - Parked gate

    private func updateGate() {
        let monitor = DrivingStateMonitor.shared
        webController.applyGate(state: monitor.state,
                                canConfirm: monitor.canConfirmParked,
                                secondsRemaining: monitor.secondsUntilParkedAllowed,
                                missingPermissions: monitor.missingPermissions)

        let allowed = monitor.state.allowsVideo
        let key = "\(allowed)-\(monitor.canConfirmParked)"
        if key != gateKey {
            gateKey = key
            if allowed {
                mapTemplate.mapButtons = browsingMapButtons()
            } else if monitor.canConfirmParked {
                mapTemplate.mapButtons = [mapButton("parkingsign.circle.fill") { _ in DrivingStateMonitor.shared.confirmParked() }]
            } else {
                mapTemplate.mapButtons = []
            }
            searchButton?.isEnabled = allowed
            sitesButton?.isEnabled = allowed
            if !allowed {
                theaterOn = false
                if mapTemplate.isPanningInterfaceVisible {
                    mapTemplate.dismissPanningInterface(animated: true)
                }
            }
        }

        if monitor.canConfirmParked && !askedAboutParking {
            askedAboutParking = true
            askIfParked()
        } else if monitor.state == .moving || monitor.state == .notConnected {
            askedAboutParking = false
        }
    }

    private func askIfParked() {
        let parked = CPAlertAction(title: "I'm Parked", style: .default) { [weak self] _ in
            DrivingStateMonitor.shared.confirmParked()
            self?.interfaceController.dismissTemplate(animated: true, completion: nil)
        }
        let notNow = CPAlertAction(title: "Not Now", style: .cancel) { [weak self] _ in
            self?.interfaceController.dismissTemplate(animated: true, completion: nil)
        }
        let alert = CPAlertTemplate(titleVariants: ["The browser works only when parked. Are you parked?", "Are you parked?"],
                                    actions: [parked, notNow])
        interfaceController.presentTemplate(alert, animated: true, completion: nil)
    }

    // MARK: - Keyboard and sites

    private func presentKeyboard(_ mode: KeyboardMode) {
        guard DrivingStateMonitor.shared.state.allowsVideo else { return }
        keyboardMode = mode
        searchText = ""
        let search = CPSearchTemplate()
        search.delegate = self
        interfaceController.pushTemplate(search, animated: true, completion: nil)
    }

    private func presentSites() {
        guard DrivingStateMonitor.shared.state.allowsVideo else { return }
        var sections: [CPListSection] = []

        if let url = BrowserTab.main.currentURL {
            sections.append(CPListSection(items: [siteItem(BrowserTab.main.title, url: url, symbol: "iphone")],
                                          header: "Open on iPhone",
                                          sectionIndexTitle: nil))
        }
        let bookmarks = LibraryStore.shared.bookmarks.compactMap { bookmark in
            bookmark.url.map { siteItem(bookmark.title, url: $0, symbol: bookmark.symbol) }
        }
        if !bookmarks.isEmpty {
            sections.append(CPListSection(items: bookmarks, header: "Bookmarks", sectionIndexTitle: nil))
        }
        let history = LibraryStore.shared.history.prefix(10).compactMap { entry in
            entry.url.map { siteItem(entry.title, url: $0, symbol: "clock") }
        }
        if !history.isEmpty {
            sections.append(CPListSection(items: Array(history), header: "Recent", sectionIndexTitle: nil))
        }
        let list = CPListTemplate(title: "Sites", sections: sections)
        interfaceController.pushTemplate(list, animated: true, completion: nil)
    }

    private func siteItem(_ title: String, url: URL, symbol: String) -> CPListItem {
        let item = CPListItem(text: title, detailText: AddressParser.displayString(for: url), image: CarPlayImages.listTile(symbol))
        item.handler = { [weak self] _, completion in
            completion()
            self?.interfaceController.popToRootTemplate(animated: true, completion: nil)
            self?.webController.tab.load(url)
        }
        return item
    }

    private func load(_ url: URL) {
        interfaceController.popToRootTemplate(animated: true, completion: nil)
        webController.tab.load(url)
    }
}

// MARK: - CPMapTemplateDelegate (touch input)

extension CarPlayWindowBrowser: CPMapTemplateDelegate {
    func mapTemplateDidBeginPanGesture(_ mapTemplate: CPMapTemplate) {
        webController.beginPan()
    }

    func mapTemplate(_ mapTemplate: CPMapTemplate, didUpdatePanGestureWithTranslation translation: CGPoint, velocity: CGPoint) {
        guard DrivingStateMonitor.shared.state.allowsVideo else { return }
        webController.updatePan(translation: translation)
    }

    func mapTemplate(_ mapTemplate: CPMapTemplate, didEndPanGestureWithVelocity velocity: CGPoint) {
        guard DrivingStateMonitor.shared.state.allowsVideo else { return }
        webController.endPan(velocity: velocity)
    }

    /// Arrow buttons of the panning interface (knob and touchpad cars) move the cursor.
    func mapTemplate(_ mapTemplate: CPMapTemplate, panWith direction: CPMapTemplate.PanDirection) {
        guard DrivingStateMonitor.shared.state.allowsVideo else { return }
        let step: CGFloat = 36
        var delta = CGPoint.zero
        if direction.contains(.up) { delta.y -= step }
        if direction.contains(.down) { delta.y += step }
        if direction.contains(.left) { delta.x -= step }
        if direction.contains(.right) { delta.x += step }
        webController.moveCursor(by: delta)
    }

    func mapTemplateDidBeginZoomGesture(_ mapTemplate: CPMapTemplate) {
        zoomStart = Date()
        zoomUpdates = 0
        zoomCenter = nil
        zoomBase = webController.pageZoom
    }

    func mapTemplate(_ mapTemplate: CPMapTemplate, didUpdateZoomGestureWithCenter center: CGPoint, scale: CGFloat, velocity: CGFloat) {
        if zoomStart == nil {
            mapTemplateDidBeginZoomGesture(mapTemplate)
        }
        zoomUpdates += 1
        zoomCenter = center
        // A real pinch streams many updates; apply them as page zoom.
        if zoomUpdates > 2, DrivingStateMonitor.shared.state.allowsVideo {
            webController.pageZoom = zoomBase * scale
        }
    }

    func mapTemplate(_ mapTemplate: CPMapTemplate, didEndZoomGestureWithVelocity velocity: CGFloat) {
        defer {
            zoomStart = nil
            zoomUpdates = 0
        }
        guard DrivingStateMonitor.shared.state.allowsVideo else { return }
        let duration = Date().timeIntervalSince(zoomStart ?? Date())
        // Double tap (the system reports it as a zoom-in): click where the finger was.
        if duration < 0.5, zoomUpdates <= 2, let center = zoomCenter {
            webController.moveCursor(to: center)
            webController.click()
        }
    }
}

// MARK: - CPSearchTemplateDelegate (CarPlay keyboard)

extension CarPlayWindowBrowser: CPSearchTemplateDelegate {
    func searchTemplate(_ searchTemplate: CPSearchTemplate,
                        updatedSearchText searchText: String,
                        completionHandler: @escaping ([CPListItem]) -> Void) {
        self.searchText = searchText
        switch keyboardMode {
        case .address:
            completionHandler(CarPlaySearchResults.items(for: searchText))
        case .typeIntoPage:
            let text = searchText.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else {
                completionHandler([])
                return
            }
            let type = CPListItem(text: "Type “\(text)”", detailText: "Into the selected field", image: CarPlayImages.listTile("keyboard"))
            type.userInfo = "type"
            let submit = CPListItem(text: "Type “\(text)” and press Return", detailText: nil, image: CarPlayImages.listTile("return"))
            submit.userInfo = "submit"
            completionHandler([submit, type])
        }
    }

    func searchTemplate(_ searchTemplate: CPSearchTemplate,
                        selectedResult item: CPListItem,
                        completionHandler: @escaping () -> Void) {
        completionHandler()
        switch keyboardMode {
        case .address:
            if let url = item.userInfo as? URL {
                load(url)
            }
        case .typeIntoPage:
            webController.typeText(searchText, submit: (item.userInfo as? String) == "submit")
            interfaceController.popToRootTemplate(animated: true, completion: nil)
        }
    }

    func searchTemplateSearchButtonPressed(_ searchTemplate: CPSearchTemplate) {
        switch keyboardMode {
        case .address:
            if let url = AddressParser.url(from: searchText) {
                load(url)
            }
        case .typeIntoPage:
            webController.typeText(searchText, submit: true)
            interfaceController.popToRootTemplate(animated: true, completion: nil)
        }
    }
}
