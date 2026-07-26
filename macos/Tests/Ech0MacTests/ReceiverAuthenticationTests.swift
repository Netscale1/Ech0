import XCTest
@testable import Ech0Mac

final class ReceiverAuthenticationTests: XCTestCase {
    func testTrustedIdentityTakesPrecedenceOverPairingToken() {
        let decision = ReceiverAuthenticationDecision.evaluate(
            authenticationMode: .trusted,
            tokenMatches: true,
            trustedIdentityMatches: true
        )

        XCTAssertTrue(decision.accepted)
        XCTAssertEqual(decision.authentication, "trusted")
    }

    func testVersionThreeRequestsPairingForUnknownSender() {
        let decision = ReceiverAuthenticationDecision.evaluate(
            authenticationMode: .trusted,
            tokenMatches: false,
            trustedIdentityMatches: false
        )

        XCTAssertFalse(decision.accepted)
        XCTAssertEqual(decision.rejectionReason, "pairingRequired")
    }

    func testOnlySecureVersionThreeWithRemoteCaptureControlIsSupported() {
        XCTAssertEqual(
            ReceiverProtocolSupport.rejectionReason(
                protocolVersion: 1,
                capabilities: ["remoteCaptureControl"]
            ),
            "unsupportedProtocol"
        )
        XCTAssertEqual(
            ReceiverProtocolSupport.rejectionReason(
                protocolVersion: 3,
                capabilities: ["remoteCaptureControl"]
            ),
            "unsupportedCapabilities"
        )
        XCTAssertNil(
            ReceiverProtocolSupport.rejectionReason(
                protocolVersion: 3,
                capabilities: ["remoteCaptureControl", "secureTransportV3"]
            )
        )
    }

    func testAuthenticationModeCannotBeDowngradedAcrossCredentialTypes() {
        XCTAssertFalse(
            ReceiverAuthenticationDecision.evaluate(
                authenticationMode: .trusted,
                tokenMatches: true,
                trustedIdentityMatches: false
            ).accepted
        )
        XCTAssertFalse(
            ReceiverAuthenticationDecision.evaluate(
                authenticationMode: .pairing,
                tokenMatches: false,
                trustedIdentityMatches: true
            ).accepted
        )
    }

    func testPairingIsNotEstablishedUntilTrustWasPersisted() {
        XCTAssertFalse(
            ReceiverTrustEstablishment.succeeds(
                trustedIdentityMatches: false,
                tokenMatches: true,
                pairingWasPersisted: false
            )
        )
        XCTAssertTrue(
            ReceiverTrustEstablishment.succeeds(
                trustedIdentityMatches: false,
                tokenMatches: true,
                pairingWasPersisted: true
            )
        )
        XCTAssertTrue(
            ReceiverTrustEstablishment.succeeds(
                trustedIdentityMatches: true,
                tokenMatches: false,
                pairingWasPersisted: false
            )
        )
    }

}
