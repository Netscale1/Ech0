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
}
