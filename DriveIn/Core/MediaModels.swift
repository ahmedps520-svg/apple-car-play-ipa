import Foundation

/// How a piece of web media is delivered, which decides where it can be played.
enum MediaStreamKind: String, Codable {
    /// HTTP Live Streaming (.m3u8). Plays in AVPlayer, so it can go to AirPlay and CarPlay.
    case hls
    /// A plain file (MP4/MOV/M4A…). Plays in AVPlayer, so it can go to AirPlay and CarPlay.
    case progressive
    /// `blob:`/Media Source Extensions or DRM. Only the web page itself can play it.
    case webOnly
    /// A format AVPlayer can't decode (WebM, DASH, Ogg…).
    case unsupported

    var label: String {
        switch self {
        case .hls: return "HLS stream"
        case .progressive: return "Video file"
        case .webOnly: return "Web player only"
        case .unsupported: return "Unsupported format"
        }
    }
}

/// A video or audio stream found on a web page (or typed in directly).
struct MediaItem: Codable, Hashable {
    var id: String
    var title: String
    var pageURL: URL?
    var streamURL: URL?
    var posterURL: URL?
    /// Seconds. `nil` when unknown.
    var duration: Double?
    var isLive: Bool
    var kind: MediaStreamKind
    var discovered: Date

    /// True when DriveIn's own player (AVPlayer) can play it, which is what AirPlay
    /// "video in car" and CarPlay video apps need.
    var isNativelyPlayable: Bool {
        streamURL != nil && (kind == .hls || kind == .progressive)
    }

    var sourceName: String {
        let host = pageURL?.host ?? streamURL?.host ?? ""
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    var detailText: String {
        var parts = [kind.label]
        if !sourceName.isEmpty { parts.append(sourceName) }
        if isLive {
            parts.append("Live")
        } else if let duration = duration, duration > 0 {
            parts.append(MediaItem.formatDuration(duration))
        }
        return parts.joined(separator: " · ")
    }

    /// A media item for a URL that already points at a stream ("…/master.m3u8").
    static func direct(url: URL, title: String? = nil) -> MediaItem {
        MediaItem(id: url.absoluteString,
                  title: title ?? url.lastPathComponent,
                  pageURL: nil,
                  streamURL: url,
                  posterURL: nil,
                  duration: nil,
                  isLive: false,
                  kind: classify(url),
                  discovered: Date())
    }

    static func classify(_ url: URL) -> MediaStreamKind {
        switch url.scheme?.lowercased() {
        case "http", "https":
            break
        default:
            return .webOnly
        }
        let ext = url.pathExtension.lowercased()
        let whole = url.absoluteString.lowercased()
        if ext == "m3u8" || whole.contains(".m3u8") || whole.contains("mpegurl") {
            return .hls
        }
        if ["webm", "ogg", "ogv", "mkv", "flv", "mpd"].contains(ext)
            || whole.contains(".mpd") || whole.contains("mime=video%2fwebm") || whole.contains("mime=audio%2fwebm") {
            return .unsupported
        }
        return .progressive
    }

    static func formatDuration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "" }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    static func youTubeVideoID(from url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        if host.hasSuffix("youtu.be") {
            return parts.first
        }
        guard host.hasSuffix("youtube.com") || host.hasSuffix("youtube-nocookie.com") else { return nil }
        if url.path == "/watch" {
            return URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "v" })?.value
        }
        if parts.count >= 2, ["shorts", "embed", "live", "v"].contains(parts[0]) {
            return parts[1]
        }
        return nil
    }

    static func youTubeThumbnailURL(for pageURL: URL) -> URL? {
        guard let id = youTubeVideoID(from: pageURL) else { return nil }
        return URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg")
    }
}

/// A link found on a web page, used to browse sites from CarPlay lists.
struct PageLink: Hashable {
    var title: String
    var url: URL
    var thumbnailURL: URL?
    var isLikelyVideo: Bool

    static func isLikelyVideoPage(_ url: URL) -> Bool {
        if MediaItem.youTubeVideoID(from: url) != nil || AddressParser.isDirectMediaURL(url) {
            return true
        }
        let host = url.host?.lowercased() ?? ""
        let path = url.path.lowercased()
        let parts = url.pathComponents.filter { $0 != "/" }
        if host.hasSuffix("vimeo.com"), let first = parts.first, Int(first) != nil {
            return true
        }
        if host.hasSuffix("dailymotion.com"), path.hasPrefix("/video/") {
            return true
        }
        if host.hasSuffix("twitch.tv") {
            return parts.count == 1 || path.contains("/videos/") || path.contains("/clip/")
        }
        return ["/video", "/watch", "/episode", "/movie", "/live"].contains { path.contains($0) }
    }
}

/// Every natively playable stream DriveIn has seen recently, newest first.
/// Shared by the iPhone UI and the CarPlay lists.
final class MediaCatalog {
    static let shared = MediaCatalog()

    private static let limit = 40
    private(set) var items: [MediaItem] = []

    private init() {}

    func record(_ newItems: [MediaItem]) {
        var changed = false
        for item in newItems where item.isNativelyPlayable {
            if let index = items.firstIndex(where: { $0.id == item.id }) {
                var merged = items[index]
                if merged.title.isEmpty || merged.title == merged.streamURL?.lastPathComponent { merged.title = item.title }
                merged.posterURL = merged.posterURL ?? item.posterURL
                merged.duration = item.duration ?? merged.duration
                if merged != items[index] {
                    items[index] = merged
                    changed = true
                }
            } else {
                items.insert(item, at: 0)
                changed = true
            }
        }
        if items.count > Self.limit {
            items.removeLast(items.count - Self.limit)
        }
        if changed {
            NotificationCenter.default.post(name: .mediaCatalogDidChange, object: self)
        }
    }

    func item(withID id: String) -> MediaItem? {
        items.first { $0.id == id }
    }

    func clear() {
        items.removeAll()
        NotificationCenter.default.post(name: .mediaCatalogDidChange, object: self)
    }
}
