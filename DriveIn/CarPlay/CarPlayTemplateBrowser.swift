import CarPlay
import CoreMedia
import UIKit

/// OFFICIAL path (iOS 27 CarPlay video app, `com.apple.developer.carplay-video` + `-audio`).
///
/// CarPlay templates can't show web pages, so DriveIn turns the web into lists: the CarPlay
/// keyboard (Search template, allowed for video apps from iOS 27) takes a URL or search, the
/// iPhone's browser tab loads it, and the page's links and playable streams come back as
/// list rows with thumbnails. Choosing a video plays it in DriveIn's AVPlayer with
/// `CPPlaybackConfiguration.preferredPresentation = .video`; the car then shows it through
/// AirPlay "video in car" when parked, or plays sound only while driving.
final class CarPlayTemplateBrowser: NSObject {
    private let interfaceController: CPInterfaceController
    private let session: CarPlaySessionMonitor
    private let tab = BrowserTab.main
    private let browseTemplate: CPListTemplate
    private let videosTemplate: CPListTemplate
    private var tabBar: CPTabBarTemplate?
    private var searchText = ""
    private var observers: [NSObjectProtocol] = []
    private var refreshScheduled = false
    private var browseSignature = ""
    private var videosSignature = ""
    private var loadingThumbnails = Set<URL>()
    private lazy var canUseNowPlaying: Bool = {
        // CPNowPlayingTemplate needs the audio entitlement. Without a profile (Simulator) trust the build.
        ProvisioningInfo.load().map { $0.has(.audio) } ?? true
    }()

    init(interfaceController: CPInterfaceController, session: CarPlaySessionMonitor) {
        self.interfaceController = interfaceController
        self.session = session
        browseTemplate = CPListTemplate(title: "DriveIn", sections: [])
        videosTemplate = CPListTemplate(title: "Videos", sections: [])
        super.init()
    }

    func start() {
        browseTemplate.tabTitle = "Browse"
        browseTemplate.tabImage = UIImage(systemName: "globe")
        browseTemplate.trailingNavigationBarButtons = [
            CPBarButton(image: CarPlayImages.symbol("magnifyingglass")) { [weak self] _ in
                self?.presentSearch()
            },
        ]
        videosTemplate.tabTitle = "Videos"
        videosTemplate.tabImage = UIImage(systemName: "play.rectangle.on.rectangle")
        videosTemplate.emptyViewTitleVariants = ["No videos yet"]
        videosTemplate.emptyViewSubtitleVariants = ["Open a site from Browse, or start a video on iPhone."]

        let tabBar = CPTabBarTemplate(templates: [browseTemplate, videosTemplate])
        self.tabBar = tabBar
        interfaceController.setRootTemplate(tabBar, animated: false, completion: nil)

        session.onChange = { [weak self] in
            self?.scheduleRefresh()
        }
        let center = NotificationCenter.default
        let names: [Notification.Name] = [.mediaCatalogDidChange, .libraryDidChange, .playbackStateDidChange,
                                          .drivingStateDidChange, .carPlaySessionDidChange]
        for name in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.scheduleRefresh()
            })
        }
        observers.append(center.addObserver(forName: .browserTabDidChange, object: tab, queue: .main) { [weak self] _ in
            self?.scheduleRefresh()
        })
        refreshAll()
    }

    func stop() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        session.onChange = nil
    }

    // MARK: - Refresh

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.refreshAll()
        }
    }

    /// Rebuilds a tab only when what it shows changed (the driving monitor ticks every
    /// second while stopped, and pages report progress constantly).
    private func refreshAll() {
        refreshScheduled = false
        let browse = currentBrowseSignature()
        if browse != browseSignature {
            browseSignature = browse
            refreshBrowse()
        }
        let videos = currentVideosSignature()
        if videos != videosSignature {
            videosSignature = videos
            refreshVideos()
        }
    }

    private func isCached(_ url: URL?) -> Bool {
        url.map { ImageLoader.shared.cachedImage(for: $0) != nil } ?? false
    }

    private func currentBrowseSignature() -> String {
        let library = LibraryStore.shared
        let current = tab.currentURL
        return [
            current?.absoluteString ?? "",
            tab.title,
            String(isCached(current.flatMap(MediaItem.youTubeThumbnailURL(for:)))),
            library.bookmarks.map { $0.urlString + $0.title }.joined(separator: ","),
            library.history.prefix(8).map { $0.urlString }.joined(separator: ","),
            String(CPListTemplate.maximumItemCount),
        ].joined(separator: "|")
    }

    private func currentVideosSignature() -> String {
        let monitor = DrivingStateMonitor.shared
        let playback = PlaybackController.shared
        return [
            MediaCatalog.shared.items.map { "\($0.id)#\($0.title)#\(isCached($0.posterURL))" }.joined(separator: ","),
            playback.currentItem?.id ?? "",
            String(playback.isPlaying),
            String(monitor.state.allowsVideo),
            String(monitor.canConfirmParked),
            String(describing: session.supportsVideoPlayback),
            String(CPListTemplate.maximumItemCount),
        ].joined(separator: "|")
    }

    private func refreshBrowse() {
        var gridButtons: [CPGridButton] = [
            CPGridButton(titleVariants: ["Go", "URL"], image: CarPlayImages.gridTile("magnifyingglass")) { [weak self] _ in
                self?.presentSearch()
            },
        ]
        for bookmark in LibraryStore.shared.bookmarks {
            guard let url = bookmark.url else { continue }
            gridButtons.append(CPGridButton(titleVariants: [bookmark.title], image: CarPlayImages.gridTile(bookmark.symbol)) { [weak self] _ in
                self?.open(url)
            })
        }
        let maximumGridButtons = CPListTemplate.maximumHeaderGridButtonCount
        browseTemplate.headerGridButtons = Array(gridButtons.prefix(max(1, maximumGridButtons)))

        var sections: [CPListSection] = []
        if let url = tab.currentURL {
            let item = CPListItem(text: tab.title,
                                  detailText: "Open on iPhone · \(AddressParser.displayString(for: url))",
                                  image: thumbnailImage(for: MediaItem.youTubeThumbnailURL(for: url), symbol: "iphone"),
                                  accessoryImage: nil,
                                  accessoryType: .disclosureIndicator)
            item.handler = { [weak self] _, completion in
                self?.showCurrentPage()
                completion()
            }
            sections.append(CPListSection(items: [item], header: "On iPhone", sectionIndexTitle: nil))
        }

        let bookmarkItems: [CPListItem] = LibraryStore.shared.bookmarks.compactMap { bookmark in
            guard let url = bookmark.url else { return nil }
            let item = CPListItem(text: bookmark.title,
                                  detailText: AddressParser.displayString(for: url),
                                  image: CarPlayImages.listTile(bookmark.symbol),
                                  accessoryImage: nil,
                                  accessoryType: .disclosureIndicator)
            item.handler = { [weak self] _, completion in
                self?.open(url)
                completion()
            }
            return item
        }
        if !bookmarkItems.isEmpty {
            sections.append(CPListSection(items: bookmarkItems, header: "Bookmarks", sectionIndexTitle: nil))
        }

        let historyItems: [CPListItem] = LibraryStore.shared.history.prefix(8).compactMap { entry in
            guard let url = entry.url else { return nil }
            let item = CPListItem(text: entry.title,
                                  detailText: AddressParser.displayString(for: url),
                                  image: CarPlayImages.listTile("clock"),
                                  accessoryImage: nil,
                                  accessoryType: .disclosureIndicator)
            item.handler = { [weak self] _, completion in
                self?.open(url)
                completion()
            }
            return item
        }
        if !historyItems.isEmpty {
            sections.append(CPListSection(items: historyItems, header: "Recent", sectionIndexTitle: nil))
        }
        browseTemplate.updateSections(trimmed(sections))
    }

    private func refreshVideos() {
        let monitor = DrivingStateMonitor.shared
        var sections: [CPListSection] = []

        if monitor.canConfirmParked {
            let item = CPListItem(text: "I'm Parked", detailText: "Turn on video for this stop", image: CarPlayImages.listTile("parkingsign.circle.fill"))
            item.handler = { _, completion in
                DrivingStateMonitor.shared.confirmParked()
                completion()
            }
            sections.append(CPListSection(items: [item], header: nil, sectionIndexTitle: nil))
        } else if session.supportsVideoPlayback == false {
            let item = CPListItem(text: "This car plays sound only", detailText: "It doesn't support CarPlay video playback.", image: CarPlayImages.listTile("speaker.wave.2.fill"))
            item.isEnabled = false
            sections.append(CPListSection(items: [item], header: nil, sectionIndexTitle: nil))
        }

        let items = MediaCatalog.shared.items.map { makeVideoItem($0) }
        if !items.isEmpty {
            sections.append(CPListSection(items: items, header: "Found while browsing", sectionIndexTitle: nil))
        }
        videosTemplate.updateSections(trimmed(sections))

        if #available(iOS 26.4, *) {
            videosTemplate.listHeader = makeNowPlayingHeader()
        }
    }

    /// Respects the car's current list limit (often 12 items while driving).
    private func trimmed(_ sections: [CPListSection]) -> [CPListSection] {
        var budget = CPListTemplate.maximumItemCount
        var result: [CPListSection] = []
        for section in sections.prefix(CPListTemplate.maximumSectionCount) where budget > 0 {
            let items = Array(section.items.prefix(budget))
            budget -= items.count
            result.append(CPListSection(items: items, header: section.header, sectionIndexTitle: nil))
        }
        return result
    }

    // MARK: - Items

    private func makeVideoItem(_ media: MediaItem) -> CPListItem {
        let item = CPListItem(text: media.title,
                              detailText: media.detailText,
                              image: thumbnailImage(for: media.posterURL, symbol: "play.rectangle.fill"))
        let playback = PlaybackController.shared
        item.isPlaying = playback.currentItem?.id == media.id && playback.isPlaying
        if #available(iOS 26.4, *) {
            item.playbackConfiguration = playbackConfiguration(for: media)
        }
        item.handler = { [weak self] _, completion in
            self?.play(media)
            completion()
        }
        return item
    }

    private func makeLinkItem(_ link: PageLink, images: [URL: UIImage]) -> CPListItem {
        let image = link.thumbnailURL.flatMap { images[$0] }.map(CarPlayImages.thumbnail)
            ?? CarPlayImages.listTile(link.isLikelyVideo ? "play.rectangle" : "link")
        let item = CPListItem(text: link.title,
                              detailText: AddressParser.displayString(for: link.url),
                              image: image,
                              accessoryImage: nil,
                              accessoryType: link.isLikelyVideo ? .none : .disclosureIndicator)
        if link.isLikelyVideo {
            if #available(iOS 26.4, *) {
                item.playbackConfiguration = CPPlaybackConfiguration(preferredPresentation: preferredPresentation(),
                                                                     playbackAction: .play,
                                                                     elapsedTime: .zero,
                                                                     duration: .zero)
            }
        }
        item.handler = { [weak self] _, completion in
            self?.openLink(link, completion: completion)
        }
        return item
    }

    /// Cached thumbnail, or a placeholder now and a refresh once the image arrives.
    private func thumbnailImage(for url: URL?, symbol: String) -> UIImage {
        guard let url = url else { return CarPlayImages.listTile(symbol) }
        if let cached = ImageLoader.shared.cachedImage(for: url) {
            return CarPlayImages.thumbnail(cached)
        }
        if !loadingThumbnails.contains(url) {
            loadingThumbnails.insert(url)
            ImageLoader.shared.load(url, maxSize: CGSize(width: 320, height: 320)) { [weak self] image in
                if image != nil {
                    self?.scheduleRefresh()
                }
            }
        }
        return CarPlayImages.listTile(symbol)
    }

    // MARK: - Playback

    /// Video when the car supports it and DriveIn considers the car parked; otherwise audio.
    private var wantsVideoPresentation: Bool {
        (session.supportsVideoPlayback ?? false) && DrivingStateMonitor.shared.state.allowsVideo
    }

    @available(iOS 26.4, *)
    private func preferredPresentation() -> CPPlaybackConfiguration.Presentation {
        wantsVideoPresentation ? .video : .audio
    }

    @available(iOS 26.4, *)
    private func playbackConfiguration(for media: MediaItem) -> CPPlaybackConfiguration {
        let playback = PlaybackController.shared
        let isCurrent = playback.currentItem?.id == media.id
        let action: CPPlaybackConfiguration.Action = isCurrent ? (playback.isPlaying ? .pause : .play) : .play
        let elapsed = isCurrent ? playback.elapsed : 0
        let duration = (isCurrent ? playback.duration : media.duration) ?? 0
        return CPPlaybackConfiguration(preferredPresentation: preferredPresentation(),
                                       playbackAction: action,
                                       elapsedTime: CMTime(seconds: elapsed, preferredTimescale: 600),
                                       duration: media.isLive ? .zero : CMTime(seconds: duration, preferredTimescale: 600))
    }

    @available(iOS 26.4, *)
    private func makeNowPlayingHeader() -> CPListTemplateDetailsHeader? {
        let playback = PlaybackController.shared
        guard let current = playback.currentItem else { return nil }
        let image = current.posterURL.flatMap { ImageLoader.shared.cachedImage(for: $0) }
            .map { ImageLoader.aspectFill($0, size: CGSize(width: 320, height: 180)) }
            ?? ImageLoader.symbolTile("play.rectangle.fill", size: CGSize(width: 320, height: 180))
        var buttons = [
            CPButton(image: CarPlayImages.symbol(playback.isPlaying ? "pause.fill" : "play.fill")) { _ in
                PlaybackController.shared.togglePlayPause()
            },
            CPButton(image: CarPlayImages.symbol("gobackward.15")) { _ in
                PlaybackController.shared.skip(by: -15)
            },
            CPButton(image: CarPlayImages.symbol("goforward.15")) { _ in
                PlaybackController.shared.skip(by: 15)
            },
        ]
        buttons = Array(buttons.prefix(max(1, CPListTemplateDetailsHeader.maximumActionButtonCount)))
        let header = CPListTemplateDetailsHeader(thumbnail: CPThumbnailImage(image: image),
                                                 title: current.title,
                                                 subtitle: current.detailText,
                                                 actionButtons: buttons)
        header.playbackConfiguration = playbackConfiguration(for: current)
        return header
    }

    private func play(_ media: MediaItem) {
        let monitor = DrivingStateMonitor.shared
        if !monitor.state.allowsVideo && monitor.canConfirmParked && (session.supportsVideoPlayback ?? false) {
            askIfParked(onParked: { [weak self] in
                self?.startPlayback(media)
            }, onAudioOnly: { [weak self] in
                self?.startPlayback(media)
            })
            return
        }
        startPlayback(media)
    }

    private func startPlayback(_ media: MediaItem) {
        PlaybackController.shared.play(media)
        // With video presentation the car shows the video itself (AirPlay "video in car").
        // Sound-only playback gets the Now Playing screen.
        if !wantsVideoPresentation {
            showNowPlaying()
        }
        scheduleRefresh()
    }

    private func showNowPlaying() {
        guard canUseNowPlaying else { return }
        let nowPlaying = CPNowPlayingTemplate.shared
        if interfaceController.topTemplate === nowPlaying {
            return
        }
        if interfaceController.templates.contains(where: { $0 === nowPlaying }) {
            interfaceController.pop(to: nowPlaying, animated: true, completion: nil)
        } else {
            interfaceController.pushRespectingDepth(nowPlaying)
        }
    }

    private func askIfParked(onParked: @escaping () -> Void, onAudioOnly: @escaping () -> Void) {
        let parked = CPAlertAction(title: "I'm Parked", style: .default) { [weak self] _ in
            DrivingStateMonitor.shared.confirmParked()
            self?.interfaceController.dismissTemplate(animated: true) { _, _ in onParked() }
        }
        let audio = CPAlertAction(title: "Sound Only", style: .cancel) { [weak self] _ in
            self?.interfaceController.dismissTemplate(animated: true) { _, _ in onAudioOnly() }
        }
        let alert = CPAlertTemplate(titleVariants: ["Video plays only when parked. Are you parked?", "Are you parked?"],
                                    actions: [parked, audio])
        interfaceController.presentTemplate(alert, animated: true, completion: nil)
    }

    // MARK: - Browsing

    private func presentSearch() {
        searchText = ""
        let search = CPSearchTemplate()
        search.delegate = self
        interfaceController.pushRespectingDepth(search)
    }

    private func open(_ url: URL) {
        if AddressParser.isDirectMediaURL(url) {
            play(MediaItem.direct(url: url))
            return
        }
        tab.load(url)
        showPage(title: AddressParser.displayString(for: url))
    }

    private func showCurrentPage() {
        showPage(title: tab.title)
    }

    /// Pushes a list for the tab's page and fills it once the page finished loading.
    private func showPage(title: String) {
        let template = CPListTemplate(title: title.isEmpty ? "Page" : title, sections: [])
        template.emptyViewTitleVariants = ["Loading…"]
        template.showsSpinnerWhileEmpty = true
        template.trailingNavigationBarButtons = [
            CPBarButton(image: CarPlayImages.symbol("arrow.clockwise")) { [weak self, weak template] _ in
                guard let self = self, let template = template else { return }
                template.updateSections([])
                self.tab.reload()
                self.fill(template)
            },
            CPBarButton(image: CarPlayImages.symbol("magnifyingglass")) { [weak self] _ in
                self?.presentSearch()
            },
        ]
        interfaceController.pushRespectingDepth(template)
        fill(template)
    }

    private func fill(_ template: CPListTemplate) {
        tab.whenLoaded(timeout: 20) { [weak self, weak template] loaded in
            // Give the page's scripts a moment to build players and lazy lists.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                guard let self = self, let template = template else { return }
                self.populate(template, loaded: loaded)
            }
        }
    }

    private func populate(_ template: CPListTemplate, loaded: Bool) {
        tab.extractLinks { [weak self, weak template] _, links in
            guard let self = self, let template = template else { return }
            let media = self.tab.playableMedia
            let budget = max(0, CPListTemplate.maximumItemCount - media.count)
            let shownLinks = Array(links.prefix(min(budget, 40)))
            let thumbnails = shownLinks.compactMap { $0.thumbnailURL } + media.compactMap { $0.posterURL }

            ImageLoader.shared.loadAll(thumbnails, maxSize: CGSize(width: 320, height: 320), timeout: 2.5) { [weak self, weak template] images in
                guard let self = self, let template = template else { return }
                var sections: [CPListSection] = []
                if !media.isEmpty {
                    sections.append(CPListSection(items: media.map { self.makeVideoItem($0) }, header: "Play", sectionIndexTitle: nil))
                }
                if !shownLinks.isEmpty {
                    sections.append(CPListSection(items: shownLinks.map { self.makeLinkItem($0, images: images) },
                                                  header: "On this page",
                                                  sectionIndexTitle: nil))
                }
                if sections.isEmpty {
                    template.showsSpinnerWhileEmpty = false
                    template.emptyViewTitleVariants = [loaded ? "Nothing to open here" : "The page didn't load"]
                    template.emptyViewSubtitleVariants = [loaded ? "Try a search instead." : "Check the connection and try again."]
                }
                template.updateSections(self.trimmed(sections))
            }
        }
    }

    /// Video-looking links: load the page and play its stream. Other links: show that page.
    private func openLink(_ link: PageLink, completion: @escaping () -> Void) {
        if AddressParser.isDirectMediaURL(link.url) {
            play(MediaItem.direct(url: link.url, title: link.title))
            completion()
            return
        }
        tab.load(link.url)
        guard link.isLikelyVideo else {
            completion()
            showPage(title: link.title)
            return
        }
        // CarPlay shows a spinner on the row until `completion` runs.
        tab.waitForPlayableMedia(timeout: 15) { [weak self] media in
            completion()
            guard let self = self else { return }
            if let media = media {
                self.play(media)
            } else {
                self.showPage(title: link.title)
            }
        }
    }
}

// MARK: - CPSearchTemplateDelegate (the CarPlay keyboard)

extension CarPlayTemplateBrowser: CPSearchTemplateDelegate {
    func searchTemplate(_ searchTemplate: CPSearchTemplate,
                        updatedSearchText searchText: String,
                        completionHandler: @escaping ([CPListItem]) -> Void) {
        self.searchText = searchText
        completionHandler(CarPlaySearchResults.items(for: searchText))
    }

    func searchTemplate(_ searchTemplate: CPSearchTemplate,
                        selectedResult item: CPListItem,
                        completionHandler: @escaping () -> Void) {
        completionHandler()
        guard let url = item.userInfo as? URL else { return }
        interfaceController.popTemplate(animated: false) { [weak self] _, _ in
            self?.open(url)
        }
    }

    func searchTemplateSearchButtonPressed(_ searchTemplate: CPSearchTemplate) {
        guard let url = AddressParser.url(from: searchText) else { return }
        interfaceController.popTemplate(animated: false) { [weak self] _, _ in
            self?.open(url)
        }
    }
}
