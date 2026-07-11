import XCTest
@testable import Ech0Mac

final class ReceiverAuthenticationTests: XCTestCase {
    func testTrustedIdentityTakesPrecedenceOverPairingToken() {
        let decision = ReceiverAuthenticationDecision.evaluate(
            protocolVersion: 2,
            tokenMatches: true,
            trustedIdentityMatches: true
        )

        XCTAssertTrue(decision.accepted)
        XCTAssertEqual(decision.authentication, "trusted")
    }

    func testVersionTwoRequestsPairingForUnknownSender() {
        let decision = ReceiverAuthenticationDecision.evaluate(
            protocolVersion: 2,
            tokenMatches: false,
            trustedIdentityMatches: false
        )

        XCTAssertFalse(decision.accepted)
        XCTAssertEqual(decision.rejectionReason, "pairingRequired")
    }

    func testVersionOneKeepsLegacyInvalidTokenReason() {
        let decision = ReceiverAuthenticationDecision.evaluate(
            protocolVersion: 1,
            tokenMatches: false,
            trustedIdentityMatches: false
        )

        XCTAssertEqual(decision.rejectionReason, "invalidToken")
    }
}
