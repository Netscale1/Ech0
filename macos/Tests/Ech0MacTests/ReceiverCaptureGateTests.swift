import XCTest
@testable import Ech0Mac

final class ReceiverCaptureGateTests: XCTestCase {
    func testSecureAudioRequiresActiveDemand() {
        XCTAssertFalse(
            ReceiverCaptureGate.acceptsAudio(
                demandActive: false
            )
        )
        XCTAssertTrue(
            ReceiverCaptureGate.acceptsAudio(
                demandActive: true
            )
        )
    }

    func testOnlyCurrentCaptureStatusGenerationIsAccepted() {
        XCTAssertTrue(ReceiverCaptureGate.acceptsStatus(generation: 4, currentGeneration: 4))
        XCTAssertFalse(ReceiverCaptureGate.acceptsStatus(generation: 3, currentGeneration: 4))
        XCTAssertFalse(ReceiverCaptureGate.acceptsStatus(generation: 5, currentGeneration: 4))
    }

    func testDisconnectedPresentationCannotRetainCapturingState() {
        XCTAssertEqual(
            ReceiverPresentationPolicy.remoteCaptureState(
                current: "capturing",
                after: .listening(port: 48_484)
            ),
            "idle"
        )
        XCTAssertEqual(
            ReceiverPresentationPolicy.remoteCaptureState(
                current: "capturing",
                after: .handshaking
            ),
            "idle"
        )
        XCTAssertEqual(
            ReceiverPresentationPolicy.remoteCaptureState(
                current: "capturing",
                after: .connected(deviceName: "Windows PC", senderId: "sender-1")
            ),
            "capturing"
        )
    }

    func testSystemInputConsumerActivatesCaptureWithoutAppSpecificSignals() {
        XCTAssertTrue(
            SystemCapturePolicy.isCaptureDemandActive(
                inputConsumerActive: true,
                manualFallbackActive: false,
                automaticDetectionAvailable: true,
                automaticCapturePaused: false
            )
        )
    }

    func testManualFallbackIsAvailableOnlyWhenSystemDetectionIsUnavailable() {
        XCTAssertTrue(
            SystemCapturePolicy.allowsManualFallback(
                automaticDetectionAvailable: false,
                automaticCapturePaused: false
            )
        )
        XCTAssertFalse(
            SystemCapturePolicy.allowsManualFallback(
                automaticDetectionAvailable: true,
                automaticCapturePaused: false
            )
        )
        XCTAssertTrue(
            SystemCapturePolicy.isCaptureDemandActive(
                inputConsumerActive: false,
                manualFallbackActive: true,
                automaticDetectionAvailable: false,
                automaticCapturePaused: false
            )
        )
        XCTAssertFalse(
            SystemCapturePolicy.isCaptureDemandActive(
                inputConsumerActive: false,
                manualFallbackActive: true,
                automaticDetectionAvailable: true,
                automaticCapturePaused: false
            )
        )
    }

    func testPauseBlocksAutomaticAndManualCaptureDemand() {
        XCTAssertFalse(
            SystemCapturePolicy.isCaptureDemandActive(
                inputConsumerActive: true,
                manualFallbackActive: true,
                automaticDetectionAvailable: false,
                automaticCapturePaused: true
            )
        )
    }
}
