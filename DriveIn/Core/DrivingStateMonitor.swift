import AVFoundation
import CoreLocation
import CoreMotion
import Foundation
import UIKit

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

/// Decides when video may play.
///
/// There is no public API that reports the gear selector or parking brake, so DriveIn combines:
/// - CarPlay connection: AVAudioSession route `.carAudio` (wired and wireless, needs no
///   entitlement) or a connected CarPlay scene (needs an entitlement).
/// - `CPSessionConfiguration.limitedUserInterfaces` (keyboard limited ⇒ the car says it is moving).
///   Only available when a CarPlay scene is connected.
/// - GPS speed from Core Location.
/// - Core Motion activity (automotive / stationary) as a fallback when GPS has no fix.
/// - An "I'm Parked" confirmation, because standing still at a red light looks identical to
///   being parked.
///
/// When DriveIn hands video to AirPlay "video in car" or the iOS 27 CarPlay video player,
/// the car itself also enforces parked-only playback (it falls back to audio-only).
final class DrivingStateMonitor: NSObject {
    static let shared = DrivingStateMonitor()

    /// ≈ 5.4 km/h. At or above this the car is moving.
    static let movingSpeed: CLLocationSpeed = 1.5
    /// ≈ 2.2 km/h. At or below this the car is standing still.
    static let stationarySpeed: CLLocationSpeed = 0.6
    /// GPS readings older than this are ignored.
    static let locationFreshness: TimeInterval = 8

    private(set) var state: DrivingState = .notConnected
    /// The car has been still long enough; waiting for the driver to tap "I'm Parked".
    private(set) var canConfirmParked = false
    private(set) var stationarySince: Date?

    // Raw signals, exposed for the diagnostics screen.
    private(set) var carPlayAudioConnected = false
    private(set) var carPlaySceneConnected = false
    private(set) var vehicleLimitsKeyboard: Bool?
    private(set) var latestSpeed: CLLocationSpeed?
    private(set) var latestLocationDate: Date?
    private(set) var motionSaysAutomotive = false
    private(set) var motionSaysStationary = false
    private(set) var latestMotionDate: Date?

    private var userConfirmedParked = false
    private let locationManager = CLLocationManager()
    private let motionManager = CMMotionActivityManager()
    private var motionRunning = false
    private var locationRunning = false
    private var requestedLocationAuthorization = false
    private var timer: Timer?
    private var started = false

    var isConnected: Bool {
        carPlayAudioConnected || carPlaySceneConnected || AppSettings.shared.drivingSimulation != .off
    }

    var locationAuthorization: CLAuthorizationStatus {
        locationManager.authorizationStatus
    }

    var motionAuthorization: CMAuthorizationStatus {
        CMMotionActivityManager.authorizationStatus()
    }

    /// Seconds left before the car counts as parked (or before "I'm Parked" becomes available).
    var secondsUntilParkedAllowed: Int? {
        guard state == .stopped, !canConfirmParked, let since = stationarySince else { return nil }
        let remaining = AppSettings.shared.parkedConfirmationDelay - Date().timeIntervalSince(since)
        return max(0, Int(remaining.rounded(.up)))
    }

    /// Human-readable reasons DriveIn can't judge the parked state.
    var missingPermissions: [String] {
        var missing: [String] = []
        switch locationAuthorization {
        case .denied, .restricted: missing.append("Location")
        default: break
        }
        if CMMotionActivityManager.isActivityAvailable() {
            switch motionAuthorization {
            case .denied, .restricted: missing.append("Motion & Fitness")
            default: break
            }
        }
        return missing
    }

    func start() {
        guard !started else { return }
        started = true

        locationManager.delegate = self
        locationManager.activityType = .automotiveNavigation
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.distanceFilter = kCLDistanceFilterNone
        locationManager.pausesLocationUpdatesAutomatically = false

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(audioRouteChanged), name: AVAudioSession.routeChangeNotification, object: nil)
        center.addObserver(self, selector: #selector(settingsChanged), name: .settingsDidChange, object: nil)
        center.addObserver(self, selector: #selector(applicationBecameActive), name: UIApplication.didBecomeActiveNotification, object: nil)

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.evaluate()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        refreshAudioRoute()
    }

    /// Shows the Location and Motion permission prompts if they haven't been answered yet.
    func requestPermissions() {
        if locationManager.authorizationStatus == .notDetermined {
            requestedLocationAuthorization = true
            locationManager.requestWhenInUseAuthorization()
        }
        if CMMotionActivityManager.isActivityAvailable(), CMMotionActivityManager.authorizationStatus() == .notDetermined {
            // Any query triggers the Motion & Fitness prompt.
            let now = Date()
            motionManager.queryActivityStarting(from: now.addingTimeInterval(-60), to: now, to: .main) { _, _ in }
        }
    }

    /// The driver says the car is parked. Only accepted after the car has been still long enough.
    func confirmParked() {
        guard canConfirmParked else { return }
        userConfirmedParked = true
        evaluate()
    }

    func setCarPlaySceneConnected(_ connected: Bool) {
        carPlaySceneConnected = connected
        if !connected {
            vehicleLimitsKeyboard = nil
        }
        evaluate()
    }

    /// From `CPSessionConfiguration.limitedUserInterfaces`; `nil` when unknown.
    func setVehicleLimitsKeyboard(_ limited: Bool?) {
        vehicleLimitsKeyboard = limited
        evaluate()
    }

    // MARK: - Signals

    @objc private func audioRouteChanged(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.refreshAudioRoute()
        }
    }

    @objc private func settingsChanged(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.evaluate()
        }
    }

    @objc private func applicationBecameActive(_ notification: Notification) {
        refreshAudioRoute()
    }

    private func refreshAudioRoute() {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        carPlayAudioConnected = outputs.contains { $0.portType == .carAudio }
        evaluate()
    }

    private func handle(_ activity: CMMotionActivity) {
        guard activity.confidence != .low else { return }
        motionSaysAutomotive = activity.automotive
        motionSaysStationary = activity.stationary
        latestMotionDate = Date()
        evaluate()
    }

    // MARK: - Sensors

    private func updateSensors() {
        if isConnected {
            startSensors()
        } else {
            stopSensors()
        }
    }

    private func startSensors() {
        if !motionRunning, CMMotionActivityManager.isActivityAvailable() {
            switch CMMotionActivityManager.authorizationStatus() {
            case .denied, .restricted:
                break
            default:
                motionRunning = true
                motionManager.startActivityUpdates(to: .main) { [weak self] activity in
                    guard let self = self, let activity = activity else { return }
                    self.handle(activity)
                }
            }
        }

        switch locationManager.authorizationStatus {
        case .notDetermined:
            if !requestedLocationAuthorization {
                requestedLocationAuthorization = true
                locationManager.requestWhenInUseAuthorization()
            }
        case .authorizedAlways, .authorizedWhenInUse:
            if !locationRunning {
                locationRunning = true
                locationManager.allowsBackgroundLocationUpdates = true
                locationManager.showsBackgroundLocationIndicator = true
                locationManager.startUpdatingLocation()
            }
        default:
            break
        }
    }

    private func stopSensors() {
        if motionRunning {
            motionRunning = false
            motionManager.stopActivityUpdates()
        }
        if locationRunning {
            locationRunning = false
            locationManager.stopUpdatingLocation()
            locationManager.allowsBackgroundLocationUpdates = false
        }
        latestSpeed = nil
        latestLocationDate = nil
        motionSaysAutomotive = false
        motionSaysStationary = false
        latestMotionDate = nil
    }

    // MARK: - Decision

    private func evaluate() {
        updateSensors()

        let now = Date()
        let settings = AppSettings.shared
        var newState: DrivingState
        var confirmable = false

        if !isConnected {
            newState = .notConnected
            stationarySince = nil
            userConfirmedParked = false
        } else {
            var speed: CLLocationSpeed?
            if let date = latestLocationDate, now.timeIntervalSince(date) < Self.locationFreshness {
                speed = latestSpeed
            }
            switch settings.drivingSimulation {
            case .off: break
            case .stopped: speed = 0
            case .driving: speed = 15
            }
            // Activity updates arrive only when the activity changes, so the last one stays current.
            let motionKnown = motionRunning && latestMotionDate != nil

            var moving = vehicleLimitsKeyboard == true
            if let speed = speed, speed >= Self.movingSpeed {
                moving = true
            }
            if speed == nil, motionKnown, motionSaysAutomotive, !motionSaysStationary {
                moving = true
            }

            let stationary: Bool
            if let speed = speed {
                stationary = speed <= Self.stationarySpeed
            } else {
                stationary = motionKnown && motionSaysStationary
            }

            if moving {
                newState = .moving
                stationarySince = nil
                userConfirmedParked = false
            } else if stationary {
                let since = stationarySince ?? now
                stationarySince = since
                if now.timeIntervalSince(since) >= settings.parkedConfirmationDelay {
                    if !settings.requireParkedConfirmation || userConfirmedParked {
                        newState = .parked
                    } else {
                        newState = .stopped
                        confirmable = true
                    }
                } else {
                    newState = .stopped
                }
            } else if state == .parked {
                // No new evidence of movement (GPS lost in a garage, speed jitter below
                // the moving threshold): stay parked until something says otherwise.
                newState = .parked
            } else if speed == nil && !motionKnown {
                newState = .unknown
                stationarySince = nil
            } else {
                // Creeping between the stationary and moving thresholds.
                newState = .stopped
                stationarySince = nil
            }
        }

        let changed = newState != state || confirmable != canConfirmParked
        state = newState
        canConfirmParked = confirmable
        // While stopped, post every tick so countdowns in the UI stay current.
        if changed || newState == .stopped {
            NotificationCenter.default.post(name: .drivingStateDidChange, object: self)
        }
    }
}

extension DrivingStateMonitor: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            switch manager.authorizationStatus {
            case .denied, .restricted:
                if self.locationRunning {
                    self.locationRunning = false
                    manager.stopUpdatingLocation()
                    manager.allowsBackgroundLocationUpdates = false
                }
            default:
                break
            }
            self.evaluate()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let validSpeed = location.speed >= 0 && location.speedAccuracy >= 0 && location.speedAccuracy <= 5
            self.latestSpeed = validSpeed ? location.speed : nil
            self.latestLocationDate = Date()
            self.evaluate()
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Keep the previous readings; they age out after `locationFreshness`.
    }
}
