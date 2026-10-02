import AVFoundation
import CoreImage
import UIKit

/// EXPERIMENTAL workaround, no entitlement needed: copies a video frame into the Now Playing
/// artwork about once a second. CarPlay's built-in Now Playing screen shows that artwork, so
/// a sideloaded app can put a (very low frame rate) picture on the car display.
/// Off by default; only runs while parked; does nothing while AirPlaying (no local frames).
final class NowPlayingFrameMirror {
    private var output: AVPlayerItemVideoOutput?
    private weak var attachedItem: AVPlayerItem?
    private weak var player: AVPlayer?
    private var timer: Timer?
    private let context = CIContext(options: nil)

    func start(player: AVPlayer) {
        self.player = player
        attachIfNeeded()
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.capture()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let item = attachedItem, let output = output {
            item.remove(output)
        }
        attachedItem = nil
        output = nil
    }

    private func attachIfNeeded() {
        guard let item = player?.currentItem else { return }
        if item === attachedItem { return }
        if let previous = attachedItem, let output = output {
            previous.remove(output)
        }
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        item.add(output)
        self.output = output
        attachedItem = item
    }

    private func capture() {
        attachIfNeeded()
        guard let player = player, !player.isExternalPlaybackActive, let item = attachedItem, let output = output else { return }
        let time = item.currentTime()
        guard output.hasNewPixelBuffer(forItemTime: time),
              let pixelBuffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil)
        else { return }

        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let longestSide = max(image.extent.width, image.extent.height)
        guard longestSide > 0 else { return }
        let scale = min(1, 640 / longestSide)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return }
        PlaybackController.shared.setLiveArtwork(UIImage(cgImage: cgImage))
    }
}
