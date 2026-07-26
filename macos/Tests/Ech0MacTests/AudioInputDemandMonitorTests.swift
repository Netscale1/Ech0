import CoreAudio
import XCTest
@testable import Ech0Mac

final class AudioInputDemandMonitorTests: XCTestCase {
    func testRequiresRunningInputOnTargetDevice() {
        XCTAssertTrue(
            AudioInputDemandMonitor.usesTargetInput(
                isRunningInput: true,
                inputDeviceIDs: [12, 44],
                targetDeviceID: 44
            )
        )
        XCTAssertFalse(
            AudioInputDemandMonitor.usesTargetInput(
                isRunningInput: false,
                inputDeviceIDs: [44],
                targetDeviceID: 44
            )
        )
        XCTAssertFalse(
            AudioInputDemandMonitor.usesTargetInput(
                isRunningInput: true,
                inputDeviceIDs: [12],
                targetDeviceID: 44
            )
        )
    }

    func testFailedStartCanBeRetried() {
        let monitor = AudioInputDemandMonitor()
        var unavailableCount = 0
        monitor.onUnavailable = { unavailableCount += 1 }

        XCTAssertFalse(monitor.start(deviceNamed: "Ech0 Missing Test Device"))
        XCTAssertFalse(monitor.start(deviceNamed: "Ech0 Missing Test Device"))
        XCTAssertEqual(unavailableCount, 2)
    }
}
