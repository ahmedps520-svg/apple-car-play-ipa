import Foundation

enum SearchEngine: String, CaseIterable {
    case google
    case duckDuckGo
    case bing
    case youTube

    var displayName: String {
        switch self {
        case .google: return "Google"
        case .duckDuckGo: return "DuckDuckGo"
        case .bing: return "Bing"
        case .youTube: return "YouTube"
        }
    }

    func searchURL(for query: String) -> URL? {
        let base: String
        let parameter: String
        switch self {
        case .google: (base, parameter) = ("https://www.google.com/search", "q")
        case .duckDuckGo: (base, parameter) = ("https://duckduckgo.com/", "q")
        case .bing: (base, parameter) = ("https://www.bing.com/search", "q")
        case .youTube: (base, parameter) = ("https://m.youtube.com/results", "search_query")
        }
        var components = URLComponents(string: base)
        components?.queryItems = [URLQueryItem(name: parameter, value: query)]
        return components?.url
    }
}

/// Lets you exercise the parked-only logic without a car.
enum DrivingSimulation: String, CaseIterable {
    case off
    /// Pretend CarPlay is connected and the car is standing still.
    case stopped
    /// Pretend CarPlay is connected and the car is moving.
    case driving

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .stopped: return "Connected, standing still"
        case .driving: return "Connected, driving"
        }
    }
}

/// User preferences, persisted in `UserDefaults`.
final class AppSettings {
    static let shared = AppSettings()

    private enum Key {
        static let searchEngine = "searchEngine"
        static let prefersDesktopSites = "prefersDesktopSites"
        static let carCompatibleVideo = "carCompatibleVideo"
        static let parkedConfirmationDelay = "parkedConfirmationDelay"
        static let requireParkedConfirmation = "requireParkedConfirmation"
        static let audioContinuesWhileDriving = "audioContinuesWhileDriving"
        static let nowPlayingFrameMirror = "nowPlayingFrameMirror"
        static let hasShownWelcome = "hasShownWelcome"
    }

    static let parkedDelayRange: ClosedRange<Double> = 3...120

    private let defaults = UserDefaults.standard

    private init() {
        defaults.register(defaults: [
            Key.searchEngine: SearchEngine.google.rawValue,
            Key.prefersDesktopSites: false,
            Key.carCompatibleVideo: true,
            Key.parkedConfirmationDelay: 10.0,
            Key.requireParkedConfirmation: true,
            Key.audioContinuesWhileDriving: true,
            Key.nowPlayingFrameMirror: false,
            Key.hasShownWelcome: false,
        ])
    }

    var searchEngine: SearchEngine {
        get { SearchEngine(rawValue: defaults.string(forKey: Key.searchEngine) ?? "") ?? .google }
        set { set(newValue.rawValue, for: Key.searchEngine) }
    }

    /// Ask sites for their desktop layout.
    var prefersDesktopSites: Bool {
        get { defaults.bool(forKey: Key.prefersDesktopSites) }
        set { set(newValue, for: Key.prefersDesktopSites) }
    }

    /// Hide Media Source Extensions from web pages so video sites fall back to plain
    /// HLS/MP4 URLs (the path older iPhones use). Those URLs can be handed to AVPlayer,
    /// which is what AirPlay "video in car" and CarPlay video apps require.
    var carCompatibleVideo: Bool {
        get { defaults.bool(forKey: Key.carCompatibleVideo) }
        set { set(newValue, for: Key.carCompatibleVideo) }
    }

    /// How long the car must stand still before DriveIn treats it as parked.
    var parkedConfirmationDelay: TimeInterval {
        get {
            let value = defaults.double(forKey: Key.parkedConfirmationDelay)
            return min(max(value, Self.parkedDelayRange.lowerBound), Self.parkedDelayRange.upperBound)
        }
        set { set(newValue, for: Key.parkedConfirmationDelay) }
    }

    /// Require an explicit "I'm Parked" tap (like Apple's "I'm Not Driving") after the
    /// car has been standing still, because sensors cannot tell a red light from Park.
    var requireParkedConfirmation: Bool {
        get { defaults.bool(forKey: Key.requireParkedConfirmation) }
        set { set(newValue, for: Key.requireParkedConfirmation) }
    }

    /// Mirror CarPlay's behaviour: when video becomes unavailable, keep the sound
    /// playing and hide the picture instead of pausing.
    var audioContinuesWhileDriving: Bool {
        get { defaults.bool(forKey: Key.audioContinuesWhileDriving) }
        set { set(newValue, for: Key.audioContinuesWhileDriving) }
    }

    /// Experimental: push video frames into the Now Playing artwork, which any app may
    /// populate and CarPlay's built-in Now Playing screen displays.
    var nowPlayingFrameMirror: Bool {
        get { defaults.bool(forKey: Key.nowPlayingFrameMirror) }
        set { set(newValue, for: Key.nowPlayingFrameMirror) }
    }

    var hasShownWelcome: Bool {
        get { defaults.bool(forKey: Key.hasShownWelcome) }
        set { defaults.set(newValue, forKey: Key.hasShownWelcome) }
    }

    /// Testing aid. Deliberately not persisted, so a relaunch always starts with real sensors.
    var drivingSimulation: DrivingSimulation = .off {
        didSet { NotificationCenter.default.post(name: .settingsDidChange, object: self) }
    }

    private func set(_ value: Any, for key: String) {
        defaults.set(value, forKey: key)
        NotificationCenter.default.post(name: .settingsDidChange, object: self)
    }
}
