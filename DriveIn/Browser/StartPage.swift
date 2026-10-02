import Foundation

/// The built-in start page: big tiles for bookmarks (easy to hit with the CarPlay cursor).
enum StartPage {
    static func html(compact: Bool) -> String {
        let tiles = LibraryStore.shared.bookmarks.map { bookmark -> String in
            let initial = bookmark.title.first.map { String($0).uppercased() } ?? "•"
            return """
            <a class="tile" href="\(escape(bookmark.urlString))">
              <span class="icon">\(escape(initial))</span>
              <span class="name">\(escape(bookmark.title))</span>
            </a>
            """
        }.joined(separator: "\n")

        let note = compact
            ? "Video plays only while parked."
            : "Type a site like <b>youtube.com</b> above. When your iPhone is connected to CarPlay, video only plays while parked."

        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
        <title>DriveIn</title>
        <style>
          :root { color-scheme: light dark; }
          body {
            margin: 0; padding: \(compact ? "12px" : "24px 16px");
            font: -apple-system-body; font-family: -apple-system, system-ui, sans-serif;
            background: #101114; color: #f2f2f7;
          }
          @media (prefers-color-scheme: light) { body { background: #f2f2f7; color: #1c1c1e; } .tile { background: #fff !important; } }
          h1 { font-size: \(compact ? "20px" : "28px"); margin: 0 0 4px; }
          p { margin: 0 0 16px; opacity: 0.7; font-size: \(compact ? "13px" : "15px"); }
          .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(\(compact ? "110px" : "100px"), 1fr)); gap: 12px; }
          .tile {
            display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 8px;
            padding: 14px 6px; border-radius: 16px; background: #1f2026; color: inherit; text-decoration: none;
            min-height: \(compact ? "84px" : "96px");
          }
          .icon {
            width: 44px; height: 44px; border-radius: 12px; display: flex; align-items: center; justify-content: center;
            background: linear-gradient(135deg, #ff9f0a, #ff375f); color: #fff; font-weight: 700; font-size: 22px;
          }
          .name { font-size: 13px; text-align: center; line-height: 1.2; }
        </style>
        </head>
        <body>
          <h1>DriveIn</h1>
          <p>\(note)</p>
          <div class="grid">
          \(tiles)
          </div>
        </body>
        </html>
        """
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
