import Foundation
import XCTest
@testable import DriveInCore

final class ParkedStateMachineTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func at(_ seconds: TimeInterval) -> Date {
        start.addingTimeInterval(seconds)
    }

    private func signals(connected: Bool = true,
                         speed: Double? = nil,
                         motionKnown: Bool = false,
                         automotive: Bool = false,
                         stationary: Bool = false,
                         keyboardLimited: Bool? = nil) -> DrivingSignals {
        DrivingSignals(isConnected: connected,
                       speed: speed,
                       motionKnown: motionKnown,
                       motionAutomotive: automotive,
                       motionStationary: stationary,
                       vehicleLimitsKeyboard: keyboardLimited)
    }

    func testNotConnectedIsUnrestricted() {
        var machine = ParkedStateMachine(parkedDelay: 10, requireConfirmation: true)
        machine.update(signals(connected: false), now: at(0))
        XCTAssertEqual(machine.state, .notConnected)
        XCTAssertTrue(machine.state.allowsVideo)
    }

    func testRedLightNeedsDelayAndConfirmation() {
        var machine = ParkedStateMachine(parkedDelay: 10, requireConfirmation: true)
        machine.update(signals(speed: 12), now: at(0))
        XCTAssertEqual(machine.state, .moving)
        XCTAssertFalse(machine.state.allowsVideo)

        machine.update(signals(speed: 0), now: at(1))
        XCTAssertEqual(machine.state, .stopped)
        XCTAssertFalse(machine.canConfirmParked)
        XCTAssertEqual(machine.secondsUntilParkedAllowed(now: at(6)), 5)
        XCTAssertFalse(machine.confirmParked(), "confirmation must not be accepted before the delay")

        machine.update(signals(speed: 0), now: at(11))
        XCTAssertEqual(machine.state, .stopped)
        XCTAssertTrue(machine.canConfirmParked)
        XCTAssertFalse(machine.state.allowsVideo)

        XCTAssertTrue(machine.confirmParked())
        machine.update(signals(speed: 0), now: at(12))
        XCTAssertEqual(machine.state, .parked)
        XCTAssertTrue(machine.state.allowsVideo)
    }

    func testParkedSurvivesLostSignalsAndJitterButNotMovement() {
        var machine = ParkedStateMachine(parkedDelay: 2, requireConfirmation: false)
        machine.update(signals(speed: 0), now: at(0))
        machine.update(signals(speed: 0), now: at(2))
        XCTAssertEqual(machine.state, .parked)

        machine.update(signals(speed: nil, motionKnown: false), now: at(30))
        XCTAssertEqual(machine.state, .parked, "losing GPS in a garage keeps the parked state")
        machine.update(signals(speed: 0.9), now: at(31))
        XCTAssertEqual(machine.state, .parked, "speed jitter below the moving threshold keeps it")

        machine.update(signals(speed: 2.0), now: at(32))
        XCTAssertEqual(machine.state, .moving)
    }

    func testMovingClearsConfirmation() {
        var machine = ParkedStateMachine(parkedDelay: 5, requireConfirmation: true)
        machine.update(signals(speed: 0), now: at(0))
        machine.update(signals(speed: 0), now: at(5))
        XCTAssertTrue(machine.confirmParked())
        machine.update(signals(speed: 0), now: at(6))
        XCTAssertEqual(machine.state, .parked)

        machine.update(signals(speed: 5), now: at(7))
        machine.update(signals(speed: 0), now: at(8))
        machine.update(signals(speed: 0), now: at(13))
        XCTAssertEqual(machine.state, .stopped)
        XCTAssertTrue(machine.canConfirmParked, "the next stop asks again")
    }

    func testCreepingRestartsTheTimer() {
        var machine = ParkedStateMachine(parkedDelay: 10, requireConfirmation: true)
        machine.update(signals(speed: 0), now: at(0))
        machine.update(signals(speed: 1.0), now: at(8))
        XCTAssertEqual(machine.state, .stopped)
        machine.update(signals(speed: 0), now: at(9))
        XCTAssertEqual(machine.secondsUntilParkedAllowed(now: at(9)), 10)
    }

    func testCarKeyboardLimitMeansMoving() {
        var machine = ParkedStateMachine(parkedDelay: 1, requireConfirmation: false)
        machine.update(signals(speed: 0, keyboardLimited: true), now: at(0))
        machine.update(signals(speed: 0, keyboardLimited: true), now: at(5))
        XCTAssertEqual(machine.state, .moving)
    }

    func testMotionFallbackWithoutGPS() {
        var machine = ParkedStateMachine(parkedDelay: 10, requireConfirmation: true)
        machine.update(signals(motionKnown: true, automotive: true, stationary: false), now: at(0))
        XCTAssertEqual(machine.state, .moving)
        machine.update(signals(motionKnown: true, automotive: true, stationary: true), now: at(1))
        machine.update(signals(motionKnown: true, automotive: true, stationary: true), now: at(11))
        XCTAssertTrue(machine.canConfirmParked)
    }

    func testNoSensorDataIsBlocked() {
        var machine = ParkedStateMachine(parkedDelay: 10, requireConfirmation: true)
        machine.update(signals(speed: nil, motionKnown: false), now: at(0))
        XCTAssertEqual(machine.state, .unknown)
        XCTAssertFalse(machine.state.allowsVideo)
        XCTAssertFalse(machine.confirmParked())
    }

    func testReconnectDoesNotKeepConfirmation() {
        var machine = ParkedStateMachine(parkedDelay: 2, requireConfirmation: true)
        machine.update(signals(speed: 0), now: at(0))
        machine.update(signals(speed: 0), now: at(2))
        XCTAssertTrue(machine.confirmParked())
        machine.update(signals(connected: false), now: at(3))
        XCTAssertEqual(machine.state, .notConnected)
        machine.update(signals(speed: 0), now: at(4))
        XCTAssertEqual(machine.state, .stopped)
        XCTAssertFalse(machine.canConfirmParked)
    }

    func testTurningConfirmationOnAsksAgain() {
        var machine = ParkedStateMachine(parkedDelay: 3, requireConfirmation: false)
        machine.update(signals(speed: 0), now: at(0))
        machine.update(signals(speed: 0), now: at(3))
        XCTAssertEqual(machine.state, .parked)
        machine.requireConfirmation = true
        machine.update(signals(speed: 0), now: at(4))
        XCTAssertEqual(machine.state, .stopped)
        XCTAssertTrue(machine.canConfirmParked)
    }

    func testUpdateReportsChanges() {
        var machine = ParkedStateMachine(parkedDelay: 10, requireConfirmation: true)
        XCTAssertTrue(machine.update(signals(speed: 10), now: at(0)))
        XCTAssertFalse(machine.update(signals(speed: 11), now: at(1)))
    }
}
