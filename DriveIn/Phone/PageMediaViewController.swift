import UIKit

/// Lists the video/audio streams found on the current page and recently elsewhere.
final class PageMediaViewController: UITableViewController {
    var onPlay: ((MediaItem) -> Void)?

    private let browserTab: BrowserTab
    private var pageItems: [MediaItem] = []
    private var recentItems: [MediaItem] = []

    init(tab: BrowserTab) {
        self.browserTab = tab
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Videos"
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        navigationItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "arrow.clockwise"), primaryAction: UIAction { [weak self] _ in
            self?.browserTab.rescanMedia()
        })
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(reloadMediaList), name: .browserTabDidChange, object: browserTab)
        center.addObserver(self, selector: #selector(reloadMediaList), name: .mediaCatalogDidChange, object: nil)
        reloadMediaList()
    }

    @objc private func reloadMediaList() {
        pageItems = browserTab.pageMedia
        let pageIDs = Set(pageItems.map { $0.id })
        recentItems = MediaCatalog.shared.items.filter { !pageIDs.contains($0.id) }
        tableView.reloadData()
    }

    private func item(at indexPath: IndexPath) -> MediaItem {
        indexPath.section == 0 ? pageItems[indexPath.row] : recentItems[indexPath.row]
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        2
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? max(pageItems.count, 1) : recentItems.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 0 ? "On this page" : (recentItems.isEmpty ? nil : "Found recently")
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard section == 0 else { return nil }
        return """
        HLS streams and video files open in DriveIn's player, which can AirPlay to the car \
        (iOS 26+ “video in car”) and is what the CarPlay video UI plays. “Web player only” \
        means the site streams through Media Source Extensions or DRM, so only the page can \
        play it. Turn on Settings ▸ Car-compatible video to make many sites use plain streams.
        """
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        var content = UIListContentConfiguration.subtitleCell()
        if indexPath.section == 0 && pageItems.isEmpty {
            content.text = "No video found yet"
            content.secondaryText = "Start a video on the page, then check again."
            content.image = UIImage(systemName: "magnifyingglass")
            content.textProperties.color = .secondaryLabel
            cell.selectionStyle = .none
            cell.accessoryType = .none
        } else {
            let media = item(at: indexPath)
            content.text = media.title
            content.secondaryText = media.detailText
            content.image = UIImage(systemName: media.isNativelyPlayable ? "play.rectangle.fill" : "lock.rectangle")
            content.imageProperties.tintColor = media.isNativelyPlayable ? .systemOrange : .secondaryLabel
            content.textProperties.numberOfLines = 2
            cell.selectionStyle = media.isNativelyPlayable ? .default : .none
            cell.accessoryType = media.isNativelyPlayable ? .disclosureIndicator : .none
        }
        content.secondaryTextProperties.color = .secondaryLabel
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !(indexPath.section == 0 && pageItems.isEmpty) else { return }
        let media = item(at: indexPath)
        guard media.isNativelyPlayable else { return }
        onPlay?(media)
    }

    override func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard !(indexPath.section == 0 && pageItems.isEmpty) else { return nil }
        let media = item(at: indexPath)
        guard let url = media.streamURL else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            UIMenu(children: [
                UIAction(title: "Copy Stream URL", image: UIImage(systemName: "doc.on.doc")) { _ in
                    UIPasteboard.general.url = url
                },
            ])
        }
    }
}
