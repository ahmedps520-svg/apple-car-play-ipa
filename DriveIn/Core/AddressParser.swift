import Foundation

/// Turns what someone typed into the address bar (or the CarPlay keyboard) into a URL.
enum AddressParser {
    /// "youtube.com" → https://youtube.com, "192.168.1.5:8096" → http://…, "cat videos" → search.
    static func url(from input: String, searchEngine: SearchEngine = AppSettings.shared.searchEngine) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = explicitURL(trimmed) {
            return url
        }
        return searchEngine.searchURL(for: trimmed)
    }

    /// Returns a URL only when the text clearly is one (scheme, host name, IP address).
    static func explicitURL(_ input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(" ") else { return nil }
        let lower = text.lowercased()

        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            return URL(string: text) ?? text.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed).flatMap(URL.init(string:))
        }

        let hostAndPort = text.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? text
        let host = hostAndPort.split(separator: ":", maxSplits: 1).first.map(String.init)?.lowercased() ?? hostAndPort
        let isLocal = host == "localhost" || isIPv4Address(host)
        guard isLocal || looksLikeDomain(host) else { return nil }

        // Local servers (Plex, Jellyfin, a NAS…) rarely have TLS certificates.
        let scheme = isLocal ? "http://" : "https://"
        return URL(string: scheme + text) ?? (scheme + text).addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed).flatMap(URL.init(string:))
    }

    /// Short, readable form for display: "m.youtube.com/watch".
    static func displayString(for url: URL?) -> String {
        guard let url = url, let host = url.host else { return "" }
        var display = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let path = url.path
        if !path.isEmpty, path != "/" {
            display += path
        }
        return display
    }

    static func isDirectMediaURL(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ["m3u8", "mp4", "m4v", "mov", "mp3", "m4a", "aac"].contains(ext)
    }

    private static func isIPv4Address(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
    }

    private static func looksLikeDomain(_ host: String) -> Bool {
        guard host.contains("."), !host.hasPrefix("."), !host.hasSuffix(".") else { return false }
        let labels = host.split(separator: ".")
        guard labels.count >= 2, let tld = labels.last, tld.count >= 2 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        let labelsValid = labels.allSatisfy { label in
            !label.isEmpty && label.unicodeScalars.allSatisfy { allowed.contains($0) }
        }
        return labelsValid && tld.allSatisfy { $0.isLetter }
    }
}
