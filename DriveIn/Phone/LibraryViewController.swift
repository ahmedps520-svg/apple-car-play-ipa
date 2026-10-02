import UIKit

/// Bookmarks and history. Bookmarks also appear as quick-access buttons in CarPlay.
final class LibraryViewController: UITableViewController {
    var onOpen: ((URL) -> Void)?

    private enum Mode: Int {
        case bookmarks
        case history
    }

    private let browserTab: BrowserTab
    private let segmented = UISegmentedControl(items: ["Bookmarks", "History"])
    private var mode: Mode = .bookmarks

    init(tab: BrowserTab) {
        self.browserTab = tab
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        segmented.selectedSegmentIndex = 0
        segmented.addAction(UIAction { [weak self] _ in
            guard let self = self else { return }
            self.mode = Mode(rawValue: self.segmented.selectedSegmentIndex) ?? .bookmarks
            self.refresh()
        }, for: .valueChanged)
        navigationItem.titleView = segmented
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        NotificationCenter.default.addObserver(self, selector: #selector(libraryChanged), name: .libraryDidChange, object: nil)
        refresh()
    }

    @objc private func libraryChanged(_ notification: Notification) {
        tableView.reloadData()
    }

    private func refresh() {
        switch mode {
        case .bookmarks:
            let current = browserTab.currentURL
            let isBookmarked = LibraryStore.shared.isBookmarked(current)
            let toggle = UIBarButtonItem(image: UIImage(systemName: isBookmarked ? "bookmark.fill" : "bookmark"), primaryAction: UIAction { [weak self] _ in
                guard let self = self, let url = self.browserTab.currentURL else { return }
                if LibraryStore.shared.isBookmarked(url) {
                    LibraryStore.shared.removeBookmark(url: url)
                } else {
                    LibraryStore.shared.addBookmark(title: self.browserTab.title, url: url)
                }
                self.refresh()
            })
            toggle.isEnabled = current != nil
            toggle.accessibilityLabel = isBookmarked ? "Remove bookmark" : "Bookmark this page"
            navigationItem.rightBarButtonItems = [toggle, editButtonItem]
        case .history:
            setEditing(false, animated: false)
            navigationItem.rightBarButtonItems = [UIBarButtonItem(title: "Clear", primaryAction: UIAction { [weak self] _ in
                LibraryStore.shared.clearHistory()
                self?.tableView.reloadData()
            })]
        }
        tableView.reloadData()
    }

    // MARK: - Table

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        mode == .bookmarks ? LibraryStore.shared.bookmarks.count : LibraryStore.shared.history.count
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        mode == .bookmarks
            ? "Bookmarks appear on the start page and as quick-access buttons in CarPlay."
            : nil
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        var content = UIListContentConfiguration.subtitleCell()
        switch mode {
        case .bookmarks:
            let bookmark = LibraryStore.shared.bookmarks[indexPath.row]
            content.text = bookmark.title
            content.secondaryText = AddressParser.displayString(for: bookmark.url)
            content.image = UIImage(systemName: bookmark.symbol)
        case .history:
            let entry = LibraryStore.shared.history[indexPath.row]
            content.text = entry.title
            content.secondaryText = AddressParser.displayString(for: entry.url)
            content.image = UIImage(systemName: "clock")
        }
        content.secondaryTextProperties.color = .secondaryLabel
        content.imageProperties.tintColor = .systemOrange
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let url: URL?
        switch mode {
        case .bookmarks: url = LibraryStore.shared.bookmarks[indexPath.row].url
        case .history: url = LibraryStore.shared.history[indexPath.row].url
        }
        if let url = url {
            onOpen?(url)
        }
    }

    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        mode == .bookmarks
    }

    override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard mode == .bookmarks, editingStyle == .delete else { return }
        LibraryStore.shared.removeBookmark(at: indexPath.row)
    }

    override func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
        mode == .bookmarks
    }

    override func tableView(_ tableView: UITableView, moveRowAt sourceIndexPath: IndexPath, to destinationIndexPath: IndexPath) {
        LibraryStore.shared.moveBookmark(from: sourceIndexPath.row, to: destinationIndexPath.row)
    }
}
