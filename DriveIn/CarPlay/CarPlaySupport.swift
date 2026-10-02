import CarPlay
import UIKit

enum CarPlayImages {
    static func symbol(_ name: String, pointSize: CGFloat = 20) -> UIImage {
        let configuration = UIImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        return UIImage(systemName: name, withConfiguration: configuration)
            ?? UIImage(systemName: "questionmark", withConfiguration: configuration)
            ?? UIImage()
    }

    /// Rounded tile with a symbol, sized for list rows.
    static func listTile(_ name: String) -> UIImage {
        ImageLoader.symbolTile(name, size: CPListItem.maximumImageSize)
    }

    /// Rounded tile with a symbol, sized for header grid buttons.
    static func gridTile(_ name: String) -> UIImage {
        let size = CPListTemplate.maximumGridButtonImageSize
        return ImageLoader.symbolTile(name, size: size.width > 0 ? size : CGSize(width: 44, height: 44))
    }

    static func thumbnail(_ image: UIImage) -> UIImage {
        ImageLoader.aspectFill(image, size: CPListItem.maximumImageSize)
    }
}

/// Results for the CarPlay keyboard (`CPSearchTemplate`): URL, site searches, matching bookmarks.
enum CarPlaySearchResults {
    static func items(for text: String) -> [CPListItem] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var items: [CPListItem] = []
        guard !query.isEmpty else {
            for bookmark in LibraryStore.shared.bookmarks.prefix(8) {
                if let url = bookmark.url {
                    items.append(item(bookmark.title, detail: AddressParser.displayString(for: url), symbol: bookmark.symbol, url: url))
                }
            }
            return items
        }
        if let url = AddressParser.explicitURL(query) {
            items.append(item("Go to \(AddressParser.displayString(for: url))", detail: url.absoluteString, symbol: "globe", url: url))
        }
        if let url = SearchEngine.youTube.searchURL(for: query) {
            items.append(item("Search YouTube for “\(query)”", detail: "m.youtube.com", symbol: "play.rectangle", url: url))
        }
        let engine = AppSettings.shared.searchEngine
        if engine != .youTube, let url = engine.searchURL(for: query) {
            items.append(item("Search \(engine.displayName) for “\(query)”", detail: nil, symbol: "magnifyingglass", url: url))
        }
        for match in LibraryStore.shared.matches(for: query, limit: 6) {
            items.append(item(match.title, detail: AddressParser.displayString(for: match.url), symbol: "clock", url: match.url))
        }
        return items
    }

    private static func item(_ text: String, detail: String?, symbol: String, url: URL) -> CPListItem {
        let item = CPListItem(text: text, detailText: detail, image: CarPlayImages.listTile(symbol))
        item.userInfo = url
        return item
    }
}

extension CPInterfaceController {
    /// Video and audio apps may stack at most 5 templates (root included). Pops back to the
    /// root first when needed so pushes never fail.
    func pushRespectingDepth(_ template: CPTemplate, maxDepth: Int = 5) {
        if templates.count >= maxDepth - 1 {
            popToRootTemplate(animated: false) { [weak self] _, _ in
                self?.pushTemplate(template, animated: true, completion: nil)
            }
        } else {
            pushTemplate(template, animated: true, completion: nil)
        }
    }
}
