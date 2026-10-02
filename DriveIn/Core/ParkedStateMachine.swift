import Foundation

/// What DriveIn believes the car is doing.
enum DrivingState: Equatable {
    /// The iPhone isn't connected to CarPlay: DriveIn is just a browser, no restrictions.
    case notConnected
    case moving
    /// Standing still, but not (yet) accepted as parked.
    case stopped
    case parked
    /// Connected, but no speed or motion data (permissions denied, no GPS fix…). Treated as unsafe.
    case unknown

    var allowsVideo: Bool {
        self == .notConnected || self == .parked
    }

    var title: String {
        switch self {
        case .notConnected: return "Not connected to CarPlay"
        case .moving: return "Driving"
        case .stopped: return "Stopped"
        case .parked: return "Parked"
        case .unknown: return "Parked status unknown"
        }
    }
}

/// One reading of everything that tells DriveIn whether the car moves.
struct DrivingSignals {
    /// Connected to CarPlay (audio route or scene), or a simulation is on.
    var isConnected: Bool
    /// Fresh, valid GPS speed in m/s; `nil` when there's none.
    var speed: Double?
    /// Core Motion has reported at least one activity since the sensors started.
    var motionKnown: Bool
    var motionAutomotive: Bool
    var motionStationary: Bool
    /// From `CPSessionConfiguration`: the car limits the keyboard (it reports driving).
    var vehicleLimitsKeyboard: Bool?
}

/// The parked-only decision, free of iOS frameworks so it can be unit tested.
///
/// Rules:
/// - Not connected → no restriction.
/// - Moving if the car limits the keyboard, GPS speed ≥ 1.5 m/s, or (without GPS) Core Motion
///   says automotive and not stationary. Moving clears any "I'm Parked" confirmation.
/// - Stopped if GPS speed ≤ 0.6 m/s, or (without GPS) Core Motion says stationary.
/// - Parked once stopped for `parkedDelay` seconds and, if required, confirmed by the driver.
/// - Once parked, losing all signals keeps it parked; only movement evidence ends it.
/// - Speeds between the two thresholds (creeping, GPS jitter) restart the stop timer.
struct ParkedStateMachine {
    static let movingSpeed: Double = 1.5
    static let stationarySpeed: Double = 0.6

    var parkedDelay: TimeInterval
    var requireConfirmation: Bool

    private(set) var state: DrivingState = .notConnected
    private(set) var canConfirmParked = false
    private(set) var stationarySince: Date?
    private var userConfirmedParked = false

    init(parkedDelay: TimeInterval, requireConfirmation: Bool) {
        self.parkedDelay = parkedDelay
        self.requireConfirmation = requireConfirmation
    }

    /// Records the driver's "I'm Parked". Only accepted while it's offered.
    @discardableResult
    mutating func confirmParked() -> Bool {
        guard canConfirmParked else { return false }
        userConfirmedParked = true
        return true
    }

    func secondsUntilParkedAllowed(now: Date) -> Int? {
        guard state == .stopped, !canConfirmParked, let since = stationarySince else { return nil }
        let remaining = parkedDelay - now.timeIntervalSince(since)
        return max(0, Int(remaining.rounded(.up)))
    }

    /// Re-evaluates; returns true when `state` or `canConfirmParked` changed.
    @discardableResult
    mutating func update(_ signals: DrivingSignals, now: Date) -> Bool {
        var newState: DrivingState
        var confirmable = false

        if !signals.isConnected {
            newState = .notConnected
            stationarySince = nil
            userConfirmedParked = false
        } else {
            let speed = signals.speed
            var moving = signals.vehicleLimitsKeyboard == true
            if let speed = speed, speed >= Self.movingSpeed {
                moving = true
            }
            if speed == nil, signals.motionKnown, signals.motionAutomotive, !signals.motionStationary {
                moving = true
            }

            let stationary: Bool
            if let speed = speed {
                stationary = speed <= Self.stationarySpeed
            } else {
                stationary = signals.motionKnown && signals.motionStationary
            }

            if moving {
                newState = .moving
                stationarySince = nil
                userConfirmedParked = false
            } else if stationary {
                let since = stationarySince ?? now
                stationarySince = since
                if now.timeIntervalSince(since) >= parkedDelay {
                    if !requireConfirmation || userConfirmedParked {
                        newState = .parked
                    } else {
                        newState = .stopped
                        confirmable = true
                    }
                } else {
                    newState = .stopped
                }
            } else if state == .parked {
                newState = .parked
            } else if speed == nil && !signals.motionKnown {
                newState = .unknown
                stationarySince = nil
            } else {
                newState = .stopped
                stationarySince = nil
            }
        }

        let changed = newState != state || confirmable != canConfirmParked
        state = newState
        canConfirmParked = confirmable
        return changed
    }
}
