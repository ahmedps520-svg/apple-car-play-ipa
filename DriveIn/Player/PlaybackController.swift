import AVFoundation
import MediaPlayer
import UIKit
import WebKit

/// DriveIn's native player. Everything that should reach the car (AirPlay "video in car",
/// the iOS 27 CarPlay video player, CarPlay Now Playing) goes through this AVPlayer.
final class PlaybackController: NSObject {
    static let shared = PlaybackController()

    let player = AVPlayer()
    private(set) var currentItem: MediaItem?
    /// True while the picture must be hidden because the car isn't parked.
    private(set) var isVideoBlocked = false
    private(set) var artwork: UIImage?

    private var pausedForDriving = false
    private var periodicObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var externalPlaybackObservation: NSKeyValueObservation?
    private let frameMirror = NowPlayingFrameMirror()

    private override init() {
        super.init()
        player.allowsExternalPlayback = true
        player.usesExternalPlaybackWhileExternalScreenIsActive = true

        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.playbackChanged() }
        }
        externalPlaybackObservation = player.observe(\.isExternalPlaybackActive, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.playbackChanged() }
        }
        periodicObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 5, preferredTimescale: 600), queue: .main) { [weak self] _ in
            self?.updateNowPlayingInfo()
        }

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(drivingStateChanged), name: .drivingStateDidChange, object: nil)
        center.addObserver(self, selector: #selector(drivingStateChanged), name: .settingsDidChange, object: nil)
        center.addObserver(self, selector: #selector(itemFinished), name: AVPlayerItem.didPlayToEndTimeNotification, object: nil)
        configureRemoteCommands()
    }

    // MARK: - State

    var isPlaying: Bool {
        player.timeControlStatus != .paused
    }

    var isAirPlaying: Bool {
        player.isExternalPlaybackActive
    }

    var elapsed: Double {
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? max(0, seconds) : 0
    }

    var duration: Double? {
        guard let seconds = player.currentItem?.duration.seconds, seconds.isFinite, seconds > 0 else {
            return currentItem?.duration
        }
        return seconds
    }

    // MARK: - Control

    /// Starts playing a natively playable stream (HLS or a plain file).
    func play(_ item: MediaItem) {
        guard let url = item.streamURL else { return }
        BrowserTab.main.pauseAllMedia()
        player.pause()
        currentItem = item
        artwork = nil
        pausedForDriving = false
        playbackChanged()

        // Streams found in the browser may need the site's cookies (signed-in sessions).
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self = self, self.currentItem?.id == item.id else { return }
            let host = url.host ?? ""
            let matching = cookies.filter { cookie in
                let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
                return host == domain || host.hasSuffix("." + domain)
            }
            self.startPlayback(item, url: url, cookies: matching)
        }
    }

    private func startPlayback(_ item: MediaItem, url: URL, cookies: [HTTPCookie]) {
        activateAudioSession()
        var options: [String: Any] = [:]
        if let userAgent = WebEnvironment.userAgent(for: .phone) {
            options[AVURLAssetHTTPUserAgentKey] = userAgent
        }
        if !cookies.isEmpty {
            options[AVURLAssetHTTPCookiesKey] = cookies
        }
        let playerItem = AVPlayerItem(asset: AVURLAsset(url: url, options: options))
        statusObservation = playerItem.observe(\.status, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.playbackChanged()
            }
        }
        player.replaceCurrentItem(with: playerItem)
        applyDrivingPolicy(startingPlayback: true)
        loadArtwork(for: item)
        playbackChanged()
    }

    var lastError: String? {
        player.currentItem?.error?.localizedDescription
    }

    func togglePlayPause() {
        isPlaying ? pause() : resume()
    }

    func resume() {
        guard player.currentItem != nil else { return }
        if !DrivingStateMonitor.shared.state.allowsVideo && !AppSettings.shared.audioContinuesWhileDriving {
            return
        }
        activateAudioSession()
        pausedForDriving = false
        player.play()
    }

    func pause() {
        player.pause()
    }

    func skip(by seconds: Double) {
        let target = max(0, elapsed + seconds)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        currentItem = nil
        artwork = nil
        frameMirror.stop()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        playbackChanged()
    }

    /// Used by the experimental Now Playing frame mirror.
    func setLiveArtwork(_ image: UIImage) {
        artwork = image
        updateNowPlayingInfo()
    }

    // MARK: - Parked-only policy

    @objc private func drivingStateChanged(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.applyDrivingPolicy(startingPlayback: false)
        }
    }

    private func applyDrivingPolicy(startingPlayback: Bool) {
        let allowsVideo = DrivingStateMonitor.shared.state.allowsVideo
        let audioContinues = AppSettings.shared.audioContinuesWhileDriving
        let wasBlocked = isVideoBlocked
        isVideoBlocked = !allowsVideo

        if startingPlayback {
            if allowsVideo || audioContinues {
                player.play()
            } else {
                pausedForDriving = true
            }
        } else if !allowsVideo && !audioContinues && isPlaying {
            player.pause()
            pausedForDriving = true
        }
        // Video never resumes on its own when the car stops; the driver presses play.

        let mirrorWanted = allowsVideo && AppSettings.shared.nowPlayingFrameMirror && currentItem != nil
        if mirrorWanted {
            frameMirror.start(player: player)
        } else {
            frameMirror.stop()
            if wasBlocked != isVideoBlocked, let item = currentItem {
                loadArtwork(for: item)
            }
        }
        if wasBlocked != isVideoBlocked || startingPlayback {
            playbackChanged()
        }
    }

    var wasPausedForDriving: Bool {
        pausedForDriving
    }

    // MARK: - Helpers

    private func activateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback, options: [])
        try? session.setActive(true)
    }

    private func loadArtwork(for item: MediaItem) {
        guard let url = item.posterURL else { return }
        ImageLoader.shared.load(url, maxSize: CGSize(width: 600, height: 600)) { [weak self] image in
            guard let self = self, let image = image, self.currentItem?.id == item.id else { return }
            self.artwork = image
            self.updateNowPlayingInfo()
        }
    }

    private func playbackChanged() {
        updateNowPlayingInfo()
        NotificationCenter.default.post(name: .playbackStateDidChange, object: self)
    }

    @objc private func itemFinished(_ notification: Notification) {
        guard (notification.object as? AVPlayerItem) === player.currentItem else { return }
        DispatchQueue.main.async { [weak self] in
            self?.playbackChanged()
        }
    }

    // MARK: - Now Playing (CarPlay's built-in Now Playing screen; no entitlement needed)

    private func updateNowPlayingInfo() {
        guard let item = currentItem else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: item.title,
            MPMediaItemPropertyArtist: item.sourceName.isEmpty ? "DriveIn" : item.sourceName,
            MPNowPlayingInfoPropertyMediaType: NSNumber(value: MPNowPlayingInfoMediaType.video.rawValue),
            MPNowPlayingInfoPropertyIsLiveStream: NSNumber(value: item.isLive),
            MPNowPlayingInfoPropertyElapsedPlaybackTime: NSNumber(value: elapsed),
            MPNowPlayingInfoPropertyPlaybackRate: NSNumber(value: player.rate),
        ]
        if let duration = duration, !item.isLive {
            info[MPMediaItemPropertyPlaybackDuration] = NSNumber(value: duration)
        }
        if let image = artwork {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func configureRemoteCommands() {
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.addTarget { [weak self] _ in
            guard let self = self, self.player.currentItem != nil else { return .noActionableNowPlayingItem }
            self.resume()
            return .success
        }
        commands.pauseCommand.addTarget { [weak self] _ in
            self?.pause()
            return .success
        }
        commands.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self = self, self.player.currentItem != nil else { return .noActionableNowPlayingItem }
            self.togglePlayPause()
            return .success
        }
        commands.skipForwardCommand.preferredIntervals = [15]
        commands.skipForwardCommand.addTarget { [weak self] _ in
            self?.skip(by: 15)
            return .success
        }
        commands.skipBackwardCommand.preferredIntervals = [15]
        commands.skipBackwardCommand.addTarget { [weak self] _ in
            self?.skip(by: -15)
            return .success
        }
        commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self = self, let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self.player.seek(to: CMTime(seconds: event.positionTime, preferredTimescale: 600))
            return .success
        }
    }
}
