import XCTest
@testable import Ech0Mac

final class CodexDictationShortcutMonitorTests: XCTestCase {
    func testTogglesOnTwoDistinctCommandPressesWithinInterval() {
        var detector = DoubleCommandDetector(maximumInterval: 0.45)

        XCTAssertFalse(detector.update(commandDown: true, otherModifierDown: false, timestamp: 1.0))
        XCTAssertFalse(detector.update(commandDown: false, otherModifierDown: false, timestamp: 1.1))
        XCTAssertTrue(detector.update(commandDown: true, otherModifierDown: false, timestamp: 1.3))
    }

    func testDoesNotRepeatWhileCommandIsHeld() {
        var detector = DoubleCommandDetector(maximumInterval: 0.45)

        XCTAssertFalse(detector.update(commandDown: true, otherModifierDown: false, timestamp: 1.0))
        XCTAssertFalse(detector.update(commandDown: true, otherModifierDown: false, timestamp: 1.1))
    }

    func testIgnoresSlowOrModifiedPresses() {
        var detector = DoubleCommandDetector(maximumInterval: 0.45)

        XCTAssertFalse(detector.update(commandDown: true, otherModifierDown: false, timestamp: 1.0))
        XCTAssertFalse(detector.update(commandDown: false, otherModifierDown: false, timestamp: 1.1))
        XCTAssertFalse(detector.update(commandDown: true, otherModifierDown: false, timestamp: 1.8))
        XCTAssertFalse(detector.update(commandDown: false, otherModifierDown: false, timestamp: 1.9))
        XCTAssertFalse(detector.update(commandDown: true, otherModifierDown: true, timestamp: 2.0))
    }

    func testMonitorCanStartAndStopRepeatedly() {
        let monitor = CodexDictationShortcutMonitor()

        monitor.start()
        XCTAssertTrue(monitor.isRunning)
        monitor.stop()
        XCTAssertFalse(monitor.isRunning)
        monitor.start()
        XCTAssertTrue(monitor.isRunning)
        monitor.stop()
        XCTAssertFalse(monitor.isRunning)
    }
}
