import CoreLocation
import CoreMotion
import Foundation
import UIKit

/// The provisioning profile the installer (Sideloadly, AltStore, Xcode…) embedded in the app.
/// Its `Entitlements` dictionary is what iOS lets this install use.
struct ProvisioningInfo {
    let name: String?
    let teamName: String?
    let creationDate: Date?
    let expirationDate: Date?
    let entitlements: [String: Any]

    /// Free Apple ID ("Personal Team") profiles expire after 7 days.
    var looksLikeFreeAccount: Bool {
        guard let created = creationDate, let expires = expirationDate else { return false }
        return expires.timeIntervalSince(created) <= 8 * 24 * 3600
    }

    func has(_ entitlement: CarPlayEntitlement) -> Bool {
        (entitlements[entitlement.rawValue] as? Bool) == true
    }

    static func load(bundle: Bundle = .main) -> ProvisioningInfo? {
        guard let url = bundle.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), options: [], in: start.lowerBound..<data.endIndex)
        else { return nil }

        let plistData = data.subdata(in: start.lowerBound..<end.upperBound)
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil),
              let dictionary = plist as? [String: Any]
        else { return nil }

        return ProvisioningInfo(
            name: dictionary["Name"] as? String,
            teamName: dictionary["TeamName"] as? String,
            creationDate: dictionary["CreationDate"] as? Date,
            expirationDate: dictionary["ExpirationDate"] as? Date,
            entitlements: dictionary["Entitlements"] as? [String: Any] ?? [:]
        )
    }
}

enum CarPlayEntitlement: String, CaseIterable {
    case video = "com.apple.developer.carplay-video"
    case audio = "com.apple.developer.carplay-audio"
    case maps = "com.apple.developer.carplay-maps"

    var label: String {
        switch self {
        case .video: return "CarPlay video app (iOS 27)"
        case .audio: return "CarPlay audio app"
        case .maps: return "CarPlay navigation app"
        }
    }
}

/// "What works on this install": the runtime answer to official-vs-workaround.
struct CapabilityReport {
    enum Status {
        case available
        case unavailable
        case conditional

        var symbol: String {
            switch self {
            case .available: return "checkmark.circle.fill"
            case .unavailable: return "xmark.circle.fill"
            case .conditional: return "exclamationmark.circle.fill"
            }
        }

        var color: UIColor {
            switch self {
            case .available: return .systemGreen
            case .unavailable: return .systemRed
            case .conditional: return .systemOrange
            }
        }
    }

    struct Row {
        let title: String
        let detail: String
        let status: Status?
    }

    struct Section {
        let title: String
        let footer: String?
        let rows: [Row]
    }

    let sections: [Section]

    static func current() -> CapabilityReport {
        let profile = ProvisioningInfo.load()
        let monitor = DrivingStateMonitor.shared
        let session = CarPlaySessionState.shared
        let hasVideo = profile?.has(.video) ?? false
        let hasAudio = profile?.has(.audio) ?? false
        let hasMaps = profile?.has(.maps) ?? false

        // What works
        var features: [Row] = []
        features.append(Row(title: "Browser + video on iPhone",
                            detail: "WKWebView, always available.",
                            status: .available))
        features.append(Row(title: "Parked-only video gate",
                            detail: monitor.missingPermissions.isEmpty
                                ? "Uses the CarPlay connection, GPS speed and motion. No entitlement needed."
                                : "Allow \(monitor.missingPermissions.joined(separator: " and ")) in Settings for reliable detection.",
                            status: monitor.missingPermissions.isEmpty ? .available : .conditional))
        features.append(Row(title: "AirPlay video to the car display",
                            detail: "Official iOS 26+ “video in car” feature. Needs no entitlement, but the car must support it, and it only works while parked. Use the AirPlay button in DriveIn's player.",
                            status: .conditional))
        features.append(Row(title: "Audio + Now Playing controls in CarPlay",
                            detail: "Any app playing audio appears in CarPlay's built-in Now Playing screen. No entitlement needed.",
                            status: .available))
        features.append(Row(title: "DriveIn icon + video browsing UI in CarPlay",
                            detail: hasVideo || hasAudio
                                ? "Your profile includes a CarPlay video/audio entitlement (official iOS 27 template UI)."
                                : "Needs com.apple.developer.carplay-video (+ -audio), which Apple grants only to paid developer accounts on request. Free Apple IDs can't sign it.",
                            status: hasVideo || hasAudio ? .available : .unavailable))
        features.append(Row(title: "Full web browser on the car screen",
                            detail: hasMaps
                                ? "Your profile includes the navigation entitlement; DriveIn draws a web view in the CarPlay map window (unsupported workaround)."
                                : "Workaround that needs com.apple.developer.carplay-maps (paid account, granted by Apple for real navigation apps only).",
                            status: hasMaps ? .available : .unavailable))

        // Signing
        var signing: [Row] = []
        if let profile = profile {
            signing.append(Row(title: "Profile", detail: profile.name ?? "Unknown", status: nil))
            if let team = profile.teamName {
                signing.append(Row(title: "Team", detail: team, status: nil))
            }
            if let expires = profile.expirationDate {
                let formatter = DateFormatter()
                formatter.dateStyle = .medium
                formatter.timeStyle = .short
                signing.append(Row(title: "Expires",
                                   detail: formatter.string(from: expires) + (profile.looksLikeFreeAccount ? " (7-day free Apple ID profile)" : ""),
                                   status: nil))
            }
        } else {
            signing.append(Row(title: "Profile",
                               detail: "No embedded.mobileprovision (Simulator, TrollStore or unsigned build).",
                               status: nil))
        }
        for entitlement in CarPlayEntitlement.allCases {
            let granted = profile?.has(entitlement) ?? false
            signing.append(Row(title: entitlement.label,
                               detail: entitlement.rawValue,
                               status: granted ? .available : .unavailable))
        }

        // Live state
        var live: [Row] = []
        live.append(Row(title: "iOS", detail: UIDevice.current.systemVersion, status: nil))
        live.append(Row(title: "CarPlay audio route",
                        detail: monitor.carPlayAudioConnected ? "Connected (wired or wireless)" : "Not connected",
                        status: nil))
        live.append(Row(title: "CarPlay scene", detail: session.mode.label, status: nil))
        if let supportsVideo = session.supportsVideoPlayback {
            live.append(Row(title: "Car supports video playback",
                            detail: supportsVideo ? "Yes (CPSessionConfiguration)" : "No: video apps play audio only",
                            status: supportsVideo ? .available : .unavailable))
        }
        if let limited = monitor.vehicleLimitsKeyboard {
            live.append(Row(title: "Car limits keyboard",
                            detail: limited ? "Yes (the car reports driving)" : "No",
                            status: nil))
        }
        live.append(Row(title: "Driving state", detail: monitor.state.title, status: monitor.state.allowsVideo ? .available : .unavailable))
        if let speed = monitor.latestSpeed {
            live.append(Row(title: "GPS speed", detail: String(format: "%.1f km/h", speed * 3.6), status: nil))
        }
        if monitor.latestMotionDate != nil {
            let activity = monitor.motionSaysAutomotive ? "Automotive" : (monitor.motionSaysStationary ? "Stationary" : "Other")
            live.append(Row(title: "Motion activity", detail: activity, status: nil))
        }
        live.append(Row(title: "Location permission", detail: describe(monitor.locationAuthorization), status: nil))
        live.append(Row(title: "Motion permission", detail: describe(monitor.motionAuthorization), status: nil))

        return CapabilityReport(sections: [
            Section(title: "What works on this install",
                    footer: "Green = works now. Orange = official, but depends on the car or permissions. Red = needs an Apple-granted CarPlay entitlement.",
                    rows: features),
            Section(title: "Signing", footer: "Read from the provisioning profile your installer embedded in DriveIn.", rows: signing),
            Section(title: "Live status", footer: nil, rows: live),
        ])
    }

    private static func describe(_ status: CLAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "Not asked yet"
        case .restricted: return "Restricted"
        case .denied: return "Denied"
        case .authorizedAlways: return "Always"
        case .authorizedWhenInUse: return "While using"
        @unknown default: return "Unknown"
        }
    }

    private static func describe(_ status: CMAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "Not asked yet"
        case .restricted: return "Restricted"
        case .denied: return "Denied"
        case .authorized: return "Allowed"
        @unknown default: return "Unknown"
        }
    }
}
