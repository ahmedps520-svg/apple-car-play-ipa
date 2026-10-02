import Foundation

/// What the connected CarPlay scene (if any) told us. Kept free of CarPlay types so the
/// iPhone UI can show it without importing the framework.
final class CarPlaySessionState {
    static let shared = CarPlaySessionState()

    enum Mode: String {
        /// No CarPlay scene. Either the car isn't connected or this install has no CarPlay entitlement.
        case none
        /// Official template UI (video/audio app entitlements).
        case templates
        /// Navigation-window browser (carplay-maps entitlement, workaround).
        case window

        var label: String {
            switch self {
            case .none: return "Not running"
            case .templates: return "Video app templates (official)"
            case .window: return "Web view in navigation window (workaround)"
            }
        }
    }

    private(set) var mode: Mode = .none
    /// `CPSessionConfiguration.supportsVideoPlayback` (iOS 26.4+). `nil` when unknown.
    private(set) var supportsVideoPlayback: Bool?
    private(set) var limitsKeyboard: Bool?
    private(set) var limitsLists: Bool?

    private init() {}

    func update(mode: Mode, supportsVideoPlayback: Bool?, limitsKeyboard: Bool?, limitsLists: Bool?) {
        self.mode = mode
        self.supportsVideoPlayback = supportsVideoPlayback
        self.limitsKeyboard = limitsKeyboard
        self.limitsLists = limitsLists
        NotificationCenter.default.post(name: .carPlaySessionDidChange, object: self)
    }

    func reset() {
        update(mode: .none, supportsVideoPlayback: nil, limitsKeyboard: nil, limitsLists: nil)
    }
}
