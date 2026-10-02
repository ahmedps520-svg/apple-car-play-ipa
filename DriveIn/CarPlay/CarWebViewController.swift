import UIKit
import WebKit

/// WORKAROUND path: the root view controller of the CarPlay navigation window, showing a real
/// web page on the car display. CarPlay never delivers taps to this window, so interaction comes
/// from `CarPlayWindowBrowser` (map buttons, pan/zoom gesture callbacks) via a cursor.
final class CarWebViewController: UIViewController {
    let browserTab = BrowserTab(surface: .car)
    /// Called when a click focused a text field; the argument is the field's current text.
    var onEditableFieldFocused: ((String) -> Void)?

    private let cursor = CursorView(frame: CGRect(x: 0, y: 0, width: 30, height: 30))
    private let gateOverlay = ParkedGateOverlayView(style: .car)
    private let toast = UILabel()
    private var cursorPoint: CGPoint?
    private var lastPanTranslation: CGPoint = .zero
    private var momentumLink: CADisplayLink?
    private var momentumVelocity: CGPoint = .zero

    override func loadView() {
        view = UIView()
        view.backgroundColor = .black
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let webView = browserTab.webView!
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isOpaque = true
        view.addSubview(webView)

        cursor.isUserInteractionEnabled = false
        view.addSubview(cursor)

        gateOverlay.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(gateOverlay)

        toast.translatesAutoresizingMaskIntoConstraints = false
        toast.font = .preferredFont(forTextStyle: .footnote)
        toast.textColor = .white
        toast.backgroundColor = UIColor(white: 0, alpha: 0.75)
        toast.textAlignment = .center
        toast.layer.cornerRadius = 10
        toast.layer.masksToBounds = true
        toast.alpha = 0
        view.addSubview(toast)

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            webView.topAnchor.constraint(equalTo: guide.topAnchor),
            webView.bottomAnchor.constraint(equalTo: guide.bottomAnchor),

            gateOverlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            gateOverlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            gateOverlay.topAnchor.constraint(equalTo: view.topAnchor),
            gateOverlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            toast.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
            toast.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -12),
            toast.heightAnchor.constraint(equalToConstant: 28),
            toast.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let frame = webFrame
        guard frame.width > 0, frame.height > 0 else { return }
        if cursorPoint == nil {
            cursorPoint = CGPoint(x: frame.midX, y: frame.midY)
        }
        positionCursor()
    }

    func loadInitialPage() {
        if let url = BrowserTab.main.currentURL {
            browserTab.load(url)
        } else {
            browserTab.showStartPage()
        }
    }

    // MARK: - Parked gate

    func applyGate(state: DrivingState, canConfirm: Bool, secondsRemaining: Int?, missingPermissions: [String]) {
        let allowed = state.allowsVideo
        gateOverlay.isHidden = allowed
        cursor.isHidden = !allowed
        gateOverlay.configure(state: state,
                              canConfirm: canConfirm,
                              secondsRemaining: secondsRemaining,
                              audioContinues: AppSettings.shared.audioContinuesWhileDriving,
                              missingPermissions: missingPermissions)
        browserTab.setMediaSuspended(!allowed && !AppSettings.shared.audioContinuesWhileDriving)
        if !allowed {
            setTheater(false)
            stopMomentum()
        }
    }

    // MARK: - Cursor and clicks

    private var webFrame: CGRect {
        browserTab.webView.frame
    }

    func moveCursor(to point: CGPoint) {
        cursorPoint = clampToWeb(point)
        positionCursor()
    }

    /// Moves the cursor; pushing it past an edge scrolls the page instead.
    func moveCursor(by delta: CGPoint) {
        guard var point = cursorPoint else { return }
        point.x += delta.x
        point.y += delta.y
        let inner = webFrame.insetBy(dx: 10, dy: 10)
        var overflow = CGPoint.zero
        if point.y < inner.minY { overflow.y = point.y - inner.minY } else if point.y > inner.maxY { overflow.y = point.y - inner.maxY }
        if point.x < inner.minX { overflow.x = point.x - inner.minX } else if point.x > inner.maxX { overflow.x = point.x - inner.maxX }
        if overflow != .zero {
            scroll(by: CGPoint(x: overflow.x * 3, y: overflow.y * 3))
        }
        cursorPoint = clampToWeb(point)
        positionCursor()
    }

    func click() {
        guard let point = cursorPoint, let fraction = webFraction(for: point) else { return }
        cursor.pulse()
        browserTab.callCarHelper("clickAt", [Double(fraction.x), Double(fraction.y)]) { [weak self] result in
            guard let json = result as? String,
                  let data = json.data(using: .utf8),
                  let info = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any]
            else { return }
            if info["editable"] as? Bool == true {
                self?.onEditableFieldFocused?(info["value"] as? String ?? "")
            }
        }
    }

    func typeText(_ text: String, submit: Bool) {
        browserTab.callCarHelper("typeText", [text, submit])
    }

    func togglePlayPause() {
        browserTab.callCarHelper("togglePlay", []) { [weak self] result in
            switch result as? String {
            case "playing": self?.showToast("Playing")
            case "paused": self?.showToast("Paused")
            default: self?.showToast("No video on this page")
            }
        }
    }

    func setTheater(_ on: Bool) {
        browserTab.callCarHelper("theater", [on]) { [weak self] result in
            if on, result as? String == "none" {
                self?.showToast("No video on this page")
            }
        }
    }

    var pageZoom: CGFloat {
        get { browserTab.webView.pageZoom }
        set { browserTab.webView.pageZoom = min(max(newValue, 0.5), 2.0) }
    }

    // MARK: - Scrolling (pan gestures from the map template)

    func beginPan() {
        stopMomentum()
        lastPanTranslation = .zero
    }

    func updatePan(translation: CGPoint) {
        let delta = CGPoint(x: translation.x - lastPanTranslation.x, y: translation.y - lastPanTranslation.y)
        lastPanTranslation = translation
        scroll(by: CGPoint(x: -delta.x, y: -delta.y))
    }

    func endPan(velocity: CGPoint) {
        lastPanTranslation = .zero
        startMomentum(CGPoint(x: -velocity.x, y: -velocity.y))
    }

    func scroll(by delta: CGPoint) {
        let scrollView = browserTab.webView.scrollView
        let inset = scrollView.adjustedContentInset
        let minOffset = CGPoint(x: -inset.left, y: -inset.top)
        let maxOffset = CGPoint(x: max(minOffset.x, scrollView.contentSize.width - scrollView.bounds.width + inset.right),
                                y: max(minOffset.y, scrollView.contentSize.height - scrollView.bounds.height + inset.bottom))
        let current = scrollView.contentOffset
        let target = CGPoint(x: min(max(current.x + delta.x, minOffset.x), maxOffset.x),
                             y: min(max(current.y + delta.y, minOffset.y), maxOffset.y))
        if target != current {
            scrollView.setContentOffset(target, animated: false)
        }
        // Feeds and carousels often scroll inside their own element, not the page.
        let remaining = CGPoint(x: delta.x - (target.x - current.x), y: delta.y - (target.y - current.y))
        if abs(remaining.x) > 1 || abs(remaining.y) > 1, let point = cursorPoint, let fraction = webFraction(for: point) {
            browserTab.callCarHelper("scrollAt", [Double(fraction.x), Double(fraction.y), Double(remaining.x), Double(remaining.y)])
        }
    }

    private func startMomentum(_ velocity: CGPoint) {
        stopMomentum()
        guard (velocity.x * velocity.x + velocity.y * velocity.y).squareRoot() > 60 else { return }
        momentumVelocity = velocity
        let link = CADisplayLink(target: self, selector: #selector(stepMomentum(_:)))
        link.add(to: .main, forMode: .common)
        momentumLink = link
    }

    private func stopMomentum() {
        momentumLink?.invalidate()
        momentumLink = nil
    }

    @objc private func stepMomentum(_ link: CADisplayLink) {
        let dt = CGFloat(max(1.0 / 120.0, min(link.targetTimestamp - link.timestamp, 1.0 / 20.0)))
        scroll(by: CGPoint(x: momentumVelocity.x * dt, y: momentumVelocity.y * dt))
        let decay = CGFloat(pow(0.94, Double(dt) * 60))
        momentumVelocity = CGPoint(x: momentumVelocity.x * decay, y: momentumVelocity.y * decay)
        let speed = (momentumVelocity.x * momentumVelocity.x + momentumVelocity.y * momentumVelocity.y).squareRoot()
        if speed < 20 {
            stopMomentum()
        }
    }

    // MARK: - Helpers

    private func clampToWeb(_ point: CGPoint) -> CGPoint {
        let frame = webFrame.insetBy(dx: 4, dy: 4)
        guard frame.width > 0, frame.height > 0 else { return point }
        return CGPoint(x: min(max(point.x, frame.minX), frame.maxX), y: min(max(point.y, frame.minY), frame.maxY))
    }

    /// Cursor position as a fraction of the web view (resolution independent for the page script).
    private func webFraction(for point: CGPoint) -> CGPoint? {
        let frame = webFrame
        guard frame.width > 0, frame.height > 0 else { return nil }
        return CGPoint(x: (point.x - frame.minX) / frame.width, y: (point.y - frame.minY) / frame.height)
    }

    private func positionCursor() {
        guard let point = cursorPoint else { return }
        cursor.center = point
        view.bringSubviewToFront(cursor)
        view.bringSubviewToFront(gateOverlay)
        view.bringSubviewToFront(toast)
    }

    private func showToast(_ text: String) {
        toast.text = "  \(text)  "
        view.bringSubviewToFront(toast)
        UIView.animate(withDuration: 0.2) {
            self.toast.alpha = 1
        } completion: { _ in
            UIView.animate(withDuration: 0.3, delay: 1.2, options: []) {
                self.toast.alpha = 0
            }
        }
    }
}

/// The on-screen pointer for the CarPlay browser.
final class CursorView: UIView {
    private let ring = CAShapeLayer()
    private let dot = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        ring.fillColor = UIColor.clear.cgColor
        ring.strokeColor = UIColor.systemOrange.cgColor
        ring.lineWidth = 3
        ring.shadowColor = UIColor.black.cgColor
        ring.shadowOpacity = 0.6
        ring.shadowRadius = 2
        ring.shadowOffset = .zero
        dot.fillColor = UIColor.systemOrange.cgColor
        layer.addSublayer(ring)
        layer.addSublayer(dot)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        ring.frame = bounds
        dot.frame = bounds
        ring.path = UIBezierPath(ovalIn: bounds.insetBy(dx: 3, dy: 3)).cgPath
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        dot.path = UIBezierPath(arcCenter: center, radius: 3, startAngle: 0, endAngle: .pi * 2, clockwise: true).cgPath
    }

    func pulse() {
        let animation = CABasicAnimation(keyPath: "transform.scale")
        animation.fromValue = 1.0
        animation.toValue = 0.6
        animation.duration = 0.12
        animation.autoreverses = true
        layer.add(animation, forKey: "pulse")
    }
}
