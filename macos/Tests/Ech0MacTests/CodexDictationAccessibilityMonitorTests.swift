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

    func testResolvesObservedVoiceChatControlsWithoutTreatingNewChatAsActive() {
        for description in ["Start voice chat", "Start new voice chat"] {
            XCTAssertEqual(
                CodexDictationAccessibilityStateResolver.resolve(buttonDescription: description),
                .inactive
            )
        }
        XCTAssertEqual(
            CodexDictationAccessibilityStateResolver.resolve(
                buttonDescription: "Stop voice chat"
            ),
            .active
        )
        XCTAssertNil(
            CodexDictationAccessibilityStateResolver.resolve(
                buttonDescription: "New voice chat"
            )
        )
        XCTAssertEqual(
            CodexDictationAccessibilityStateResolver.resolve(
                buttonDescriptions: ["Start voice chat", "Stop voice chat"]
            ),
            .active
        )
    }

    func testResolvesItalianComposerAndGlobalDictationControls() {
        XCTAssertEqual(
            CodexDictationAccessibilityStateResolver.resolve(buttonDescription: "Detta"),
            .inactive
        )
        for description in ["Arresta dettatura", "Trascrivi e invia", "Interrompi dettatura"] {
            XCTAssertEqual(
                CodexDictationAccessibilityStateResolver.resolve(buttonDescription: description),
                .active
            )
        }
    }

    func testResolutionIsCaseAndWhitespaceInsensitive() {
        XCTAssertEqual(
            CodexDictationAccessibilityStateResolver.resolve(buttonDescription: "  ARRESTA DETTATURA  "),
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

    func testAnyActiveComposerTakesPrecedenceOverInactiveComposer() {
        XCTAssertEqual(
            CodexDictationAccessibilityStateResolver.resolve(
                buttonDescriptions: ["Dictate", "Stop dictation"]
            ),
            .active
        )
        XCTAssertEqual(
            CodexDictationAccessibilityStateResolver.resolve(
                buttonDescriptions: ["Transcribe and send", "Dictate"]
            ),
            .active
        )
    }

    func testMultipleInactiveComposersRemainInactive() {
        XCTAssertEqual(
            CodexDictationAccessibilityStateResolver.resolve(
                buttonDescriptions: ["Dictate", "Unrelated", "Dictate"]
            ),
            .inactive
        )
    }

    func testOnlyResolvedUIStatesAreAvailable() {
        XCTAssertTrue(CodexDictationAccessibilityState.inactive.isAvailable)
        XCTAssertTrue(CodexDictationAccessibilityState.active.isAvailable)
        XCTAssertFalse(CodexDictationAccessibilityState.unavailable.isAvailable)
        XCTAssertFalse(CodexDictationAccessibilityState.permissionRequired.isAvailable)
    }

    func testManualFallbackIsAllowedOnlyWithoutResolvedAccessibilityState() {
        for state in [
            CodexDictationAccessibilityState.unavailable,
            .permissionRequired,
        ] {
            XCTAssertTrue(
                CodexCapturePolicy.allowsManualFallback(
                    accessibilityState: state,
                    automaticCapturePaused: false
                )
            )
        }
        for state in [
            CodexDictationAccessibilityState.inactive,
            .active,
        ] {
            XCTAssertFalse(
                CodexCapturePolicy.allowsManualFallback(
                    accessibilityState: state,
                    automaticCapturePaused: false
                )
            )
        }
        XCTAssertFalse(
            CodexCapturePolicy.allowsManualFallback(
                accessibilityState: .unavailable,
                automaticCapturePaused: true
            )
        )
    }

    func testManualFallbackCannotOverrideResolvedInactiveState() {
        XCTAssertFalse(
            CodexCapturePolicy.isCaptureDemandActive(
                accessibilityState: .inactive,
                manualFallbackActive: true,
                independentInputConsumerActive: false,
                automaticCapturePaused: false
            )
        )
        XCTAssertTrue(
            CodexCapturePolicy.isCaptureDemandActive(
                accessibilityState: .unavailable,
                manualFallbackActive: true,
                independentInputConsumerActive: false,
                automaticCapturePaused: false
            )
        )
    }

    func testAutomaticAndIndependentCaptureSignalsRemainEffective() {
        XCTAssertTrue(
            CodexCapturePolicy.isCaptureDemandActive(
                accessibilityState: .active,
                manualFallbackActive: false,
                independentInputConsumerActive: false,
                automaticCapturePaused: false
            )
        )
        XCTAssertTrue(
            CodexCapturePolicy.isCaptureDemandActive(
                accessibilityState: .inactive,
                manualFallbackActive: false,
                independentInputConsumerActive: true,
                automaticCapturePaused: false
            )
        )
        XCTAssertFalse(
            CodexCapturePolicy.isCaptureDemandActive(
                accessibilityState: .active,
                manualFallbackActive: false,
                independentInputConsumerActive: true,
                automaticCapturePaused: true
            )
        )
    }

    func testPriorityEventBypassesFiveSecondFallbackDelay() {
        var schedule = CodexAccessibilityFullScanSchedule(fallbackInterval: 5)
        schedule.didScan(at: 10)

        XCTAssertFalse(
            schedule.shouldScan(
                at: 11,
                cachedControlsBecameInvalid: false,
                hasPublishedState: true
            )
        )

        schedule.requestPriorityScan()

        XCTAssertTrue(
            schedule.shouldScan(
                at: 11,
                cachedControlsBecameInvalid: false,
                hasPublishedState: true
            )
        )
    }

    func testFullScanScheduleClassifiesLifecycleReasonsAndResets() {
        var schedule = CodexAccessibilityFullScanSchedule(fallbackInterval: 5)

        XCTAssertEqual(
            schedule.scanReason(
                at: 10,
                cachedControlsBecameInvalid: false,
                hasPublishedState: false
            ),
            .initial
        )

        schedule.didScan(at: 10)
        XCTAssertNil(
            schedule.scanReason(
                at: 14,
                cachedControlsBecameInvalid: false,
                hasPublishedState: true
            )
        )
        XCTAssertEqual(
            schedule.scanReason(
                at: 14,
                cachedControlsBecameInvalid: true,
                hasPublishedState: true
            ),
            .cacheInvalidated
        )
        XCTAssertEqual(
            schedule.scanReason(
                at: 15,
                cachedControlsBecameInvalid: false,
                hasPublishedState: true
            ),
            .interval
        )

        schedule.requestPriorityScan()
        XCTAssertEqual(
            schedule.scanReason(
                at: 15,
                cachedControlsBecameInvalid: true,
                hasPublishedState: true
            ),
            .priority
        )

        schedule.reset()
        XCTAssertEqual(
            schedule.scanReason(
                at: 15,
                cachedControlsBecameInvalid: false,
                hasPublishedState: false
            ),
            .initial
        )
    }

    func testApplicationFallbackBackoffDoesNotDelayPriorityOrRecoveryScans() {
        var schedule = CodexAccessibilityFullScanSchedule(
            fallbackInterval: 5,
            applicationFallbackInterval: 10
        )
        schedule.didScan(at: 10, scope: .application)

        XCTAssertFalse(schedule.allowsApplicationFallback(at: 15, reason: .interval))
        XCTAssertTrue(schedule.allowsApplicationFallback(at: 20, reason: .interval))
        XCTAssertTrue(schedule.allowsApplicationFallback(at: 15, reason: .priority))
        XCTAssertTrue(schedule.allowsApplicationFallback(at: 15, reason: .cacheInvalidated))
        XCTAssertTrue(schedule.allowsApplicationFallback(at: 15, reason: .targetChanged))

        schedule.didScan(at: 15, scope: .focusedAncestry)
        XCTAssertTrue(schedule.allowsApplicationFallback(at: 20, reason: .interval))
        schedule.reset()
        XCTAssertTrue(schedule.allowsApplicationFallback(at: 0, reason: .interval))
    }

    func testScanActivityReportsOverlapAndRecoversAfterEnd() {
        var activity = CodexAccessibilityScanActivity()

        XCTAssertFalse(activity.begin())
        XCTAssertTrue(activity.begin())
        activity.end()
        XCTAssertFalse(activity.begin())
        activity.end()
    }

    func testFocusedAncestryIsLimitedToSafeSteadyStateScans() {
        for reason in [
            CodexAccessibilityFullScanReason.interval,
            .priority,
        ] {
            XCTAssertEqual(
                CodexAccessibilityScanScopePolicy.preferredScope(
                    reason: reason,
                    windowCount: 1,
                    cachedControlCount: 1
                ),
                .focusedAncestry
            )
        }

        for reason in [
            CodexAccessibilityFullScanReason.initial,
            .cacheInvalidated,
            .targetChanged,
        ] {
            XCTAssertEqual(
                CodexAccessibilityScanScopePolicy.preferredScope(
                    reason: reason,
                    windowCount: 1,
                    cachedControlCount: 1
                ),
                .application
            )
        }
        XCTAssertEqual(
            CodexAccessibilityScanScopePolicy.preferredScope(
                reason: .interval,
                windowCount: 2,
                cachedControlCount: 1
            ),
            .application
        )
        XCTAssertEqual(
            CodexAccessibilityScanScopePolicy.preferredScope(
                reason: .interval,
                windowCount: 1,
                cachedControlCount: 0
            ),
            .application
        )
        XCTAssertEqual(
            CodexAccessibilityScanScopePolicy.preferredScope(
                reason: .interval,
                windowCount: 1,
                cachedControlCount: 2
            ),
            .application
        )
    }

    func testTargetLifecycleRecoversAfterErrorAndProcessRestart() {
        var lifecycle = CodexAccessibilityTargetLifecycle()

        XCTAssertTrue(lifecycle.observe(pid: 101))
        XCTAssertFalse(lifecycle.observe(pid: 101))
        XCTAssertTrue(lifecycle.observe(pid: nil))
        XCTAssertNil(lifecycle.pid)
        XCTAssertTrue(lifecycle.observe(pid: 202))
        XCTAssertEqual(lifecycle.pid, 202)
        lifecycle.reset()
        XCTAssertNil(lifecycle.pid)
    }

    func testMonitorCanStartAndStopRepeatedly() {
        let monitor = CodexDictationAccessibilityMonitor(
            bundleIdentifier: "net.ech0.missing-test-app"
        )

        monitor.start(promptForPermission: false)
        XCTAssertTrue(monitor.isRunning)
        monitor.stop()
        XCTAssertFalse(monitor.isRunning)
        monitor.start(promptForPermission: false)
        XCTAssertTrue(monitor.isRunning)
        monitor.stop()
        XCTAssertFalse(monitor.isRunning)
    }
}
