import XCTest
@testable import Ech0Mac

final class ReceiverConnectionLivenessTests: XCTestCase {
    func testHandshakeExpiresAfterTimeout() {
        XCTAssertNil(
            ReceiverConnectionLiveness.timeoutReason(
                didHandshake: false,
                acceptedAt: 10,
                lastPingAt: nil,
                now: 15,
                timeout: 5
            )
        )
        XCTAssertEqual(
            ReceiverConnectionLiveness.timeoutReason(
                didHandshake: false,
                acceptedAt: 10,
                lastPingAt: nil,
                now: 15.1,
                timeout: 5
            ),
            "handshakeTimeout"
        )
    }

    func testHeartbeatExpiresAfterTimeout() {
        XCTAssertNil(
            ReceiverConnectionLiveness.timeoutReason(
                didHandshake: true,
                acceptedAt: 10,
                lastPingAt: 20,
                now: 25,
                timeout: 5
            )
        )
        XCTAssertEqual(
            ReceiverConnectionLiveness.timeoutReason(
                didHandshake: true,
                acceptedAt: 10,
                lastPingAt: 20,
                now: 25.1,
                timeout: 5
            ),
            "heartbeatTimeout"
        )
    }

    func testMissingPingAfterHandshakeIsStale() {
        XCTAssertEqual(
            ReceiverConnectionLiveness.timeoutReason(
                didHandshake: true,
                acceptedAt: 10,
                lastPingAt: nil,
                now: 10,
                timeout: 5
            ),
            "heartbeatTimeout"
        )
    }
}
