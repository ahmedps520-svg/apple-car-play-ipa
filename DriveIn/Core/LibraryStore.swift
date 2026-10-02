import Foundation

struct WebBookmark: Codable, Hashable {
    var title: String
    var urlString: String
    /// SF Symbol shown on the iPhone and in CarPlay.
    var symbol: String

    var url: URL? { URL(string: urlString) }
}

struct HistoryEntry: Codable, Hashable {
    var title: String
    var urlString: String
    var visited: Date

    var url: URL? { URL(string: urlString) }
}

/// Bookmarks and history, stored as JSON in Application Support.
final class LibraryStore {
    static let shared = LibraryStore()

    static let defaultBookmarks: [WebBookmark] = [
        WebBookmark(title: "YouTube", urlString: "https://m.youtube.com/", symbol: "play.rectangle.fill"),
        WebBookmark(title: "Netflix", urlString: "https://www.netflix.com/", symbol: "film"),
        WebBookmark(title: "Twitch", urlString: "https://m.twitch.tv/", symbol: "dot.radiowaves.left.and.right"),
        WebBookmark(title: "Vimeo", urlString: "https://vimeo.com/watch", symbol: "video"),
        WebBookmark(title: "Dailymotion", urlString: "https://www.dailymotion.com/", symbol: "play.tv"),
        WebBookmark(
            title: "Test stream (Apple HLS)",
            urlString: "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8",
            symbol: "checkmark.seal"
        ),
    ]

    private struct Snapshot: Codable {
        var bookmarks: [WebBookmark]
        var history: [HistoryEntry]
    }

    private static let historyLimit = 200

    private(set) var bookmarks: [WebBookmark]
    private(set) var history: [HistoryEntry]
    private let fileURL: URL

    private init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("library.json")

        if let data = try? Data(contentsOf: fileURL),
           let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
            bookmarks = snapshot.bookmarks
            history = snapshot.history
        } else {
            bookmarks = Self.defaultBookmarks
            history = []
        }
    }

    // MARK: Bookmarks

    func isBookmarked(_ url: URL?) -> Bool {
        guard let url = url else { return false }
        return bookmarks.contains { $0.urlString == url.absoluteString }
    }

    func addBookmark(title: String, url: URL) {
        guard !isBookmarked(url) else { return }
        let name = title.isEmpty ? (url.host ?? url.absoluteString) : title
        bookmarks.append(WebBookmark(title: name, urlString: url.absoluteString, symbol: "globe"))
        save()
    }

    func removeBookmark(url: URL) {
        bookmarks.removeAll { $0.urlString == url.absoluteString }
        save()
    }

    func removeBookmark(at index: Int) {
        guard bookmarks.indices.contains(index) else { return }
        bookmarks.remove(at: index)
        save()
    }

    func moveBookmark(from source: Int, to destination: Int) {
        guard bookmarks.indices.contains(source) else { return }
        let bookmark = bookmarks.remove(at: source)
        bookmarks.insert(bookmark, at: min(max(destination, 0), bookmarks.count))
        save()
    }

    func restoreDefaultBookmarks() {
        bookmarks = Self.defaultBookmarks
        save()
    }

    // MARK: History

    func recordVisit(title: String, url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return }
        let entry = HistoryEntry(title: title.isEmpty ? (url.host ?? url.absoluteString) : title,
                                 urlString: url.absoluteString,
                                 visited: Date())
        if let first = history.first, first.urlString == entry.urlString {
            history[0] = entry
        } else {
            history.removeAll { $0.urlString == entry.urlString }
            history.insert(entry, at: 0)
        }
        if history.count > Self.historyLimit {
            history.removeLast(history.count - Self.historyLimit)
        }
        save()
    }

    func clearHistory() {
        history.removeAll()
        save()
    }

    // MARK: Search

    /// Bookmarks first, then history entries, matching title or URL.
    func matches(for text: String, limit: Int) -> [(title: String, url: URL)] {
        let needle = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return [] }
        var results: [(title: String, url: URL)] = []
        var seen = Set<String>()
        func consider(_ title: String, _ urlString: String) {
            guard results.count < limit, !seen.contains(urlString), let url = URL(string: urlString) else { return }
            if title.lowercased().contains(needle) || urlString.lowercased().contains(needle) {
                seen.insert(urlString)
                results.append((title, url))
            }
        }
        bookmarks.forEach { consider($0.title, $0.urlString) }
        history.forEach { consider($0.title, $0.urlString) }
        return results
    }

    private func save() {
        let snapshot = Snapshot(bookmarks: bookmarks, history: history)
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: fileURL, options: .atomic)
        }
        NotificationCenter.default.post(name: .libraryDidChange, object: self)
    }
}
