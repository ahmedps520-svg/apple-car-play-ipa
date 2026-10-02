import UIKit

/// Small in-memory thumbnail loader used for posters and CarPlay list images.
final class ImageLoader {
    static let shared = ImageLoader()

    private let cache = NSCache<NSURL, UIImage>()
    private let session: URLSession

    private init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 8
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        session = URLSession(configuration: configuration)
        cache.countLimit = 200
    }

    func cachedImage(for url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    /// Loads, downsizes to fit `maxSize` (points) and calls back on the main queue.
    func load(_ url: URL, maxSize: CGSize, completion: @escaping (UIImage?) -> Void) {
        if let cached = cachedImage(for: url) {
            completion(cached)
            return
        }
        session.dataTask(with: url) { [weak self] data, _, _ in
            var result: UIImage?
            if let data = data, let image = UIImage(data: data) {
                result = ImageLoader.resize(image, toFit: maxSize)
            }
            DispatchQueue.main.async {
                if let result = result {
                    self?.cache.setObject(result, forKey: url as NSURL)
                }
                completion(result)
            }
        }.resume()
    }

    /// Loads several images at once and calls back when all finished or `timeout` passed.
    func loadAll(_ urls: [URL], maxSize: CGSize, timeout: TimeInterval, completion: @escaping ([URL: UIImage]) -> Void) {
        let unique = Array(Set(urls))
        guard !unique.isEmpty else {
            completion([:])
            return
        }
        var results: [URL: UIImage] = [:]
        var remaining = unique.count
        var finished = false
        func finish() {
            guard !finished else { return }
            finished = true
            completion(results)
        }
        for url in unique {
            load(url, maxSize: maxSize) { image in
                if let image = image {
                    results[url] = image
                }
                remaining -= 1
                if remaining == 0 {
                    finish()
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            finish()
        }
    }

    static func resize(_ image: UIImage, toFit maxSize: CGSize) -> UIImage {
        let size = image.size
        guard size.width > 0, size.height > 0, maxSize.width > 0, maxSize.height > 0 else { return image }
        let scale = min(maxSize.width / size.width, maxSize.height / size.height, 1)
        let target = CGSize(width: max(1, floor(size.width * scale)), height: max(1, floor(size.height * scale)))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 2
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    /// An image cropped to fill `size` exactly (used for uniform CarPlay thumbnails).
    static func aspectFill(_ image: UIImage, size: CGSize) -> UIImage {
        let source = image.size
        guard source.width > 0, source.height > 0 else { return image }
        let scale = max(size.width / source.width, size.height / source.height)
        let drawSize = CGSize(width: source.width * scale, height: source.height * scale)
        let origin = CGPoint(x: (size.width - drawSize.width) / 2, y: (size.height - drawSize.height) / 2)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 2
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: origin, size: drawSize))
        }
    }

    /// A rounded square with a symbol, for list rows without a thumbnail.
    static func symbolTile(_ symbolName: String, size: CGSize, tint: UIColor = .systemOrange) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 2
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            let rect = CGRect(origin: .zero, size: size)
            UIColor(white: 0.18, alpha: 1).setFill()
            UIBezierPath(roundedRect: rect, cornerRadius: min(size.width, size.height) * 0.2).fill()
            let configuration = UIImage.SymbolConfiguration(pointSize: min(size.width, size.height) * 0.45, weight: .semibold)
            if let symbol = UIImage(systemName: symbolName, withConfiguration: configuration)?
                .withTintColor(tint, renderingMode: .alwaysOriginal) {
                let symbolSize = symbol.size
                symbol.draw(in: CGRect(x: (size.width - symbolSize.width) / 2,
                                       y: (size.height - symbolSize.height) / 2,
                                       width: symbolSize.width,
                                       height: symbolSize.height))
            }
        }
    }
}
