import XCTest
@testable import Ech0Mac

final class CodexDictationAccessibilityMonitorTests: XCTestCase {
    func testResolvesInactiveDictationButton() {
        XCTAssertEqual(
            CodexDictationAccessibilityStateResolver.resolve(buttonDescription: "Dictate"),
            .inactive
        )
    }

    func testResolvesBothActiveDictationControls() {
        XCTAssertEqual(
            CodexDictationAccessibilityStateResolver.resolve(
                buttonDescription: "Stop dictation"
            ),
            .active
        )
        XCTAssertEqual(
            CodexDictationAccessibilityStateResolver.resolve(
                buttonDescription: "Transcribe and send"
            ),
            .active
        )
    }

    func testIgnoresUnrelatedButtons() {
        XCTAssertNil(
            CodexDictationAccessibilityStateResolver.resolve(buttonDescription: "Stop")
        )
        XCTAssertNil(
            CodexDictationAccessibilityStateResolver.resolve(buttonDescription: "Send")
        )
    }

    func testOnlyResolvedUIStatesAreAvailable() {
        XCTAssertTrue(CodexDictationAccessibilityState.inactive.isAvailable)
        XCTAssertTrue(CodexDictationAccessibilityState.active.isAvailable)
        XCTAssertFalse(CodexDictationAccessibilityState.unavailable.isAvailable)
        XCTAssertFalse(CodexDictationAccessibilityState.permissionRequired.isAvailable)
    }
}
