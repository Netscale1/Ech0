import XCTest
@testable import Ech0Mac

final class ReceiverErrorTests: XCTestCase {
    func testMissingAudioEndpointExplainsDedicatedAndOptionalFallback() {
        let error = ReceiverError.audioEndpointUnavailable(fallbackName: "BlackHole 2ch")

        XCTAssertEqual(
            error.errorDescription,
            "Install Ech0 Virtual Microphone or the optional BlackHole 2ch fallback."
        )
    }
}
