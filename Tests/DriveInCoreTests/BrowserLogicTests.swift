import Foundation
import XCTest
@testable import DriveInCore

final class AddressParserTests: XCTestCase {
    func testBareDomainsBecomeHTTPS() {
        XCTAssertEqual(AddressParser.url(from: "youtube.com", searchEngine: .google)?.absoluteString, "https://youtube.com")
        XCTAssertEqual(AddressParser.url(from: "netflix.com/browse", searchEngine: .google)?.absoluteString, "https://netflix.com/browse")
        XCTAssertEqual(AddressParser.url(from: "m.youtube.com/watch?v=abc", searchEngine: .google)?.absoluteString,
                       "https://m.youtube.com/watch?v=abc")
    }

    func testLocalServersUseHTTP() {
        XCTAssertEqual(AddressParser.url(from: "192.168.1.5:8096", searchEngine: .google)?.absoluteString, "http://192.168.1.5:8096")
        XCTAssertEqual(AddressParser.url(from: "localhost:3000/x", searchEngine: .google)?.absoluteString, "http://localhost:3000/x")
    }

    func testOtherTextIsSearched() {
        XCTAssertEqual(AddressParser.url(from: "cat videos", searchEngine: .google)?.absoluteString,
                       "https://www.google.com/search?q=cat%20videos")
        XCTAssertEqual(AddressParser.url(from: "lofi", searchEngine: .youTube)?.absoluteString,
                       "https://m.youtube.com/results?search_query=lofi")
        XCTAssertNil(AddressParser.explicitURL("hello"))
        XCTAssertNil(AddressParser.url(from: "   ", searchEngine: .google))
    }

    func testDisplayString() {
        XCTAssertEqual(AddressParser.displayString(for: URL(string: "https://www.youtube.com/watch?v=1")), "youtube.com/watch")
        XCTAssertEqual(AddressParser.displayString(for: URL(string: "https://vimeo.com/")), "vimeo.com")
        XCTAssertEqual(AddressParser.displayString(for: nil), "")
    }
}

final class MediaModelTests: XCTestCase {
    func testClassification() {
        XCTAssertEqual(MediaItem.classify(URL(string: "https://a.example/v/master.m3u8?token=1")!), .hls)
        XCTAssertEqual(MediaItem.classify(URL(string: "https://r1.googlevideo.com/videoplayback?mime=video%2Fmp4&itag=18")!), .progressive)
        XCTAssertEqual(MediaItem.classify(URL(string: "https://r1.googlevideo.com/videoplayback?mime=video%2Fwebm")!), .unsupported)
        XCTAssertEqual(MediaItem.classify(URL(string: "https://a.example/manifest.mpd")!), .unsupported)
        XCTAssertEqual(MediaItem.classify(URL(string: "blob:https://www.youtube.com/123")!), .webOnly)
    }

    func testOnlyPlainStreamsArePlayable() {
        XCTAssertTrue(MediaItem.direct(url: URL(string: "https://a.example/master.m3u8")!).isNativelyPlayable)
        XCTAssertFalse(MediaItem.direct(url: URL(string: "https://a.example/clip.webm")!).isNativelyPlayable)
    }

    func testYouTubeIDs() {
        XCTAssertEqual(MediaItem.youTubeVideoID(from: URL(string: "https://m.youtube.com/watch?v=dQw4w9WgXcQ&t=3")!), "dQw4w9WgXcQ")
        XCTAssertEqual(MediaItem.youTubeVideoID(from: URL(string: "https://youtu.be/dQw4w9WgXcQ")!), "dQw4w9WgXcQ")
        XCTAssertEqual(MediaItem.youTubeVideoID(from: URL(string: "https://www.youtube.com/shorts/abc123")!), "abc123")
        XCTAssertNil(MediaItem.youTubeVideoID(from: URL(string: "https://www.youtube.com/feed/trending")!))
        XCTAssertEqual(MediaItem.youTubeThumbnailURL(for: URL(string: "https://youtu.be/xyz")!)?.absoluteString,
                       "https://i.ytimg.com/vi/xyz/hqdefault.jpg")
    }

    func testVideoPageDetection() {
        XCTAssertTrue(PageLink.isLikelyVideoPage(URL(string: "https://vimeo.com/123456")!))
        XCTAssertFalse(PageLink.isLikelyVideoPage(URL(string: "https://vimeo.com/about")!))
        XCTAssertTrue(PageLink.isLikelyVideoPage(URL(string: "https://m.twitch.tv/somechannel")!))
        XCTAssertTrue(PageLink.isLikelyVideoPage(URL(string: "https://www.dailymotion.com/video/x8abc")!))
    }

    func testDurationFormatting() {
        XCTAssertEqual(MediaItem.formatDuration(3725), "1:02:05")
        XCTAssertEqual(MediaItem.formatDuration(65), "1:05")
        XCTAssertEqual(MediaItem.formatDuration(.infinity), "")
    }
}

final class WebScriptsTests: XCTestCase {
    func testCarCallEncodesArguments() {
        XCTAssertEqual(WebScripts.carCall("clickAt", [0.5, 0.25]),
                       "window.__driveInCar ? window.__driveInCar.clickAt(0.5, 0.25) : null")
        XCTAssertEqual(WebScripts.carCall("theater", [false]),
                       "window.__driveInCar ? window.__driveInCar.theater(false) : null")
        let typed = WebScripts.carCall("typeText", ["say \"hi\"\n</script>", true])
        XCTAssertTrue(typed.contains("typeText(\"say \\\"hi\\\"\\n"), typed)
        XCTAssertFalse(typed.contains("</script>"), "the closing tag must be escaped")
    }

    func testStartPageListsBookmarks() {
        let html = StartPage.html(compact: false)
        XCTAssertTrue(html.contains("YouTube"))
        XCTAssertTrue(html.contains("https://m.youtube.com/"))
    }
}
