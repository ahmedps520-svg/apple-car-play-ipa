import AVKit
import UIKit
import WebKit

/// The iPhone browser.
final class BrowserViewController: UIViewController {
    private let browserTab: BrowserTab

    private let topBar = UIView()
    private let addressField = UITextField()
    private let reloadButton = UIButton(type: .system)
    private let statusButton = UIButton(type: .system)
    private let progressView = UIProgressView(progressViewStyle: .bar)
    private let webContainer = UIView()
    private let gateOverlay = ParkedGateOverlayView(style: .phone)
    private let toolbar = UIToolbar()

    private var backItem: UIBarButtonItem!
    private var forwardItem: UIBarButtonItem!
    private var videosItem: UIBarButtonItem!
    private var bookmarkItem: UIBarButtonItem!

    init(tab: BrowserTab) {
        self.browserTab = tab
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        buildTopBar()
        buildWebArea()
        buildToolbar()
        layout()

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(tabChanged), name: .browserTabDidChange, object: browserTab)
        center.addObserver(self, selector: #selector(drivingStateChanged), name: .drivingStateDidChange, object: nil)
        center.addObserver(self, selector: #selector(drivingStateChanged), name: .settingsDidChange, object: nil)
        center.addObserver(self, selector: #selector(libraryChanged), name: .libraryDidChange, object: nil)

        if browserTab.webView.url == nil {
            browserTab.showStartPage()
        }
        refreshNavigation()
        refreshGate()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !AppSettings.shared.hasShownWelcome {
            AppSettings.shared.hasShownWelcome = true
            showWelcome()
        }
    }

    /// Opens a URL from elsewhere (CarPlay, the library…).
    func open(_ url: URL) {
        browserTab.load(url)
    }

    // MARK: - Building

    private func buildTopBar() {
        topBar.backgroundColor = .secondarySystemBackground
        topBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topBar)

        addressField.placeholder = "Search or enter website"
        addressField.borderStyle = .none
        addressField.backgroundColor = .tertiarySystemFill
        addressField.layer.cornerRadius = 12
        addressField.layer.cornerCurve = .continuous
        addressField.font = .preferredFont(forTextStyle: .body)
        addressField.keyboardType = .webSearch
        addressField.returnKeyType = .go
        addressField.autocapitalizationType = .none
        addressField.autocorrectionType = .no
        addressField.spellCheckingType = .no
        addressField.clearButtonMode = .whileEditing
        addressField.textContentType = .URL
        addressField.delegate = self
        addressField.translatesAutoresizingMaskIntoConstraints = false

        let magnifier = UIImageView(image: UIImage(systemName: "magnifyingglass"))
        magnifier.tintColor = .secondaryLabel
        magnifier.contentMode = .center
        magnifier.frame = CGRect(x: 0, y: 0, width: 34, height: 34)
        addressField.leftView = magnifier
        addressField.leftViewMode = .always

        reloadButton.setImage(UIImage(systemName: "arrow.clockwise"), for: .normal)
        reloadButton.frame = CGRect(x: 0, y: 0, width: 38, height: 34)
        reloadButton.addAction(UIAction { [weak self] _ in self?.reloadOrStop() }, for: .touchUpInside)
        addressField.rightView = reloadButton
        addressField.rightViewMode = .unlessEditing
        topBar.addSubview(addressField)

        var status = UIButton.Configuration.tinted()
        status.cornerStyle = .capsule
        status.buttonSize = .mini
        status.imagePadding = 6
        statusButton.configuration = status
        statusButton.translatesAutoresizingMaskIntoConstraints = false
        statusButton.addAction(UIAction { [weak self] _ in self?.showCapabilities() }, for: .touchUpInside)
        topBar.addSubview(statusButton)

        progressView.translatesAutoresizingMaskIntoConstraints = false
        progressView.trackTintColor = .clear
        view.addSubview(progressView)
    }

    private func buildWebArea() {
        webContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webContainer)

        let webView = browserTab.webView!
        webView.translatesAutoresizingMaskIntoConstraints = false
        webContainer.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: webContainer.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: webContainer.trailingAnchor),
            webView.topAnchor.constraint(equalTo: webContainer.topAnchor),
            webView.bottomAnchor.constraint(equalTo: webContainer.bottomAnchor),
        ])

        gateOverlay.translatesAutoresizingMaskIntoConstraints = false
        gateOverlay.onConfirmParked = {
            DrivingStateMonitor.shared.confirmParked()
        }
        gateOverlay.onOpenSettings = {
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        }
        view.addSubview(gateOverlay)
    }

    private func buildToolbar() {
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(toolbar)

        backItem = UIBarButtonItem(image: UIImage(systemName: "chevron.backward"), primaryAction: UIAction { [weak self] _ in
            self?.browserTab.goBack()
        })
        forwardItem = UIBarButtonItem(image: UIImage(systemName: "chevron.forward"), primaryAction: UIAction { [weak self] _ in
            self?.browserTab.goForward()
        })
        videosItem = UIBarButtonItem(image: UIImage(systemName: "play.rectangle.on.rectangle"), primaryAction: UIAction { [weak self] _ in
            self?.showPageMedia()
        })
        videosItem.accessibilityLabel = "Videos on this page"

        let routePicker = AVRoutePickerView(frame: CGRect(x: 0, y: 0, width: 32, height: 32))
        routePicker.prioritizesVideoDevices = true
        routePicker.activeTintColor = .systemOrange
        let airPlayItem = UIBarButtonItem(customView: routePicker)
        airPlayItem.accessibilityLabel = "AirPlay"

        bookmarkItem = UIBarButtonItem(image: UIImage(systemName: "book"), primaryAction: UIAction { [weak self] _ in
            self?.showLibrary()
        })
        bookmarkItem.accessibilityLabel = "Bookmarks and history"
        let settingsItem = UIBarButtonItem(image: UIImage(systemName: "gearshape"), primaryAction: UIAction { [weak self] _ in
            self?.showSettings()
        })

        let flexible = { UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil) }
        toolbar.items = [backItem, flexible(), forwardItem, flexible(), videosItem, flexible(), airPlayItem, flexible(), bookmarkItem, flexible(), settingsItem]
    }

    private func layout() {
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBar.topAnchor.constraint(equalTo: view.topAnchor),

            addressField.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 12),
            addressField.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -12),
            addressField.topAnchor.constraint(equalTo: guide.topAnchor, constant: 6),
            addressField.heightAnchor.constraint(equalToConstant: 40),

            statusButton.topAnchor.constraint(equalTo: addressField.bottomAnchor, constant: 6),
            statusButton.centerXAnchor.constraint(equalTo: topBar.centerXAnchor),
            statusButton.bottomAnchor.constraint(equalTo: topBar.bottomAnchor, constant: -6),

            progressView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progressView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            progressView.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            progressView.heightAnchor.constraint(equalToConstant: 2),

            webContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webContainer.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            webContainer.bottomAnchor.constraint(equalTo: toolbar.topAnchor),

            gateOverlay.leadingAnchor.constraint(equalTo: webContainer.leadingAnchor),
            gateOverlay.trailingAnchor.constraint(equalTo: webContainer.trailingAnchor),
            gateOverlay.topAnchor.constraint(equalTo: webContainer.topAnchor),
            gateOverlay.bottomAnchor.constraint(equalTo: webContainer.bottomAnchor),

            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            toolbar.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
        ])
    }

    // MARK: - Updates

    @objc private func tabChanged(_ notification: Notification) {
        refreshNavigation()
    }

    @objc private func libraryChanged(_ notification: Notification) {
        refreshNavigation()
    }

    @objc private func drivingStateChanged(_ notification: Notification) {
        refreshGate()
    }

    private func refreshNavigation() {
        let webView = browserTab.webView!
        if !addressField.isFirstResponder {
            addressField.text = AddressParser.displayString(for: browserTab.currentURL)
        }
        reloadButton.setImage(UIImage(systemName: webView.isLoading ? "xmark" : "arrow.clockwise"), for: .normal)
        progressView.setProgress(Float(webView.estimatedProgress), animated: webView.isLoading)
        progressView.isHidden = !webView.isLoading
        backItem.isEnabled = webView.canGoBack || !browserTab.isShowingStartPage
        forwardItem.isEnabled = webView.canGoForward

        let playable = browserTab.playableMedia.count
        videosItem.image = UIImage(systemName: playable > 0 ? "play.rectangle.on.rectangle.fill" : "play.rectangle.on.rectangle")
        videosItem.tintColor = playable > 0 ? .systemOrange : nil
        bookmarkItem.image = UIImage(systemName: LibraryStore.shared.isBookmarked(browserTab.currentURL) ? "book.fill" : "book")
    }

    private func refreshGate() {
        let monitor = DrivingStateMonitor.shared
        let state = monitor.state
        let audioContinues = AppSettings.shared.audioContinuesWhileDriving

        gateOverlay.isHidden = state.allowsVideo
        gateOverlay.configure(state: state,
                              canConfirm: monitor.canConfirmParked,
                              secondsRemaining: monitor.secondsUntilParkedAllowed,
                              audioContinues: audioContinues,
                              missingPermissions: monitor.missingPermissions)
        // The overlay hides the picture; suspend media too unless sound should continue.
        browserTab.setMediaSuspended(!state.allowsVideo && !audioContinues)
        if !state.allowsVideo {
            addressField.resignFirstResponder()
        }

        if state == .notConnected {
            statusButton.isHidden = true
        } else {
            statusButton.isHidden = false
            var configuration = statusButton.configuration ?? UIButton.Configuration.tinted()
            let color: UIColor
            switch state {
            case .parked: color = .systemGreen
            case .stopped: color = .systemOrange
            default: color = .systemRed
            }
            var title = "CarPlay · \(state.title)"
            if let seconds = monitor.secondsUntilParkedAllowed {
                title += " · \(seconds)s"
            }
            if AppSettings.shared.drivingSimulation != .off {
                title += " (simulated)"
            }
            configuration.title = title
            configuration.image = UIImage(systemName: state.allowsVideo ? "play.circle.fill" : "pause.circle.fill")
            configuration.baseForegroundColor = color
            configuration.baseBackgroundColor = color
            statusButton.configuration = configuration
        }
    }

    // MARK: - Actions

    private func reloadOrStop() {
        if browserTab.webView.isLoading {
            browserTab.stopLoading()
        } else {
            browserTab.reload()
        }
    }

    private func showPageMedia() {
        let controller = PageMediaViewController(tab: browserTab)
        controller.onPlay = { [weak self] item in
            self?.dismiss(animated: true) {
                self?.presentPlayer(for: item)
            }
        }
        presentSheet(controller)
    }

    func presentPlayer(for item: MediaItem) {
        PlaybackController.shared.play(item)
        let player = PlayerViewController()
        player.modalPresentationStyle = .fullScreen
        present(player, animated: true)
    }

    private func showLibrary() {
        let controller = LibraryViewController(tab: browserTab)
        controller.onOpen = { [weak self] url in
            self?.dismiss(animated: true)
            self?.browserTab.load(url)
        }
        presentSheet(controller)
    }

    private func showSettings() {
        presentSheet(SettingsViewController(style: .insetGrouped))
    }

    private func showCapabilities() {
        presentSheet(CapabilitiesViewController(style: .insetGrouped))
    }

    private func presentSheet(_ controller: UIViewController) {
        let navigation = UINavigationController(rootViewController: controller)
        if let sheet = navigation.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        present(navigation, animated: true)
    }

    private func showWelcome() {
        let alert = UIAlertController(
            title: "Welcome to DriveIn",
            message: "Browse any site and play video, AirPlay it to your car's display (on cars that support it), or open DriveIn in CarPlay if your install has a CarPlay entitlement.\n\nWhile your iPhone is connected to CarPlay, video only plays when the car is parked. DriveIn uses Location and Motion to tell.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Allow Location & Motion", style: .default) { _ in
            DrivingStateMonitor.shared.requestPermissions()
        })
        alert.addAction(UIAlertAction(title: "What works on my install?", style: .default) { [weak self] _ in
            DrivingStateMonitor.shared.requestPermissions()
            self?.showCapabilities()
        })
        present(alert, animated: true)
    }
}

extension BrowserViewController: UITextFieldDelegate {
    func textFieldDidBeginEditing(_ textField: UITextField) {
        textField.text = browserTab.currentURL?.absoluteString
        DispatchQueue.main.async {
            textField.selectAll(nil)
        }
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        textField.text = AddressParser.displayString(for: browserTab.currentURL)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        let text = textField.text ?? ""
        textField.resignFirstResponder()
        if browserTab.load(input: text) {
            textField.text = AddressParser.displayString(for: browserTab.currentURL)
        }
        return true
    }
}
