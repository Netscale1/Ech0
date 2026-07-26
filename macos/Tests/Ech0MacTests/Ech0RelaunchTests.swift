import XCTest
@testable import Ech0Mac

final class Ech0RelaunchTests: XCTestCase {
    func testRelaunchProcessWaitsThenOpensSameBundleAsNewInstance() {
        let process = makeEch0RelaunchProcess(bundlePath: "/Applications/Ech0Mac.app")

        XCTAssertEqual(process.executableURL?.path, "/bin/sh")
        XCTAssertEqual(
            process.arguments,
            [
                "-c",
                "sleep 0.5; exec /usr/bin/open -n \"$1\"",
                "ech0-restart",
                "/Applications/Ech0Mac.app"
            ]
        )
    }
}
