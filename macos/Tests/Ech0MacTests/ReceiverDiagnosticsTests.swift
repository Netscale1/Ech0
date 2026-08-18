import XCTest
@testable import Ech0Mac

final class ReceiverDiagnosticsTests: XCTestCase {
    func testReportContainsCurrentStateMetricsRTTAndEvents() {
        let report = ReceiverDiagnosticsSnapshot(
            appVersion: "0.2.0 (2)",
            driverVersion: "0.2.0 (2)",
            protocolVersion: 3,
            connection: "Connected",
            audioInput: "Ech0 Virtual Microphone",
            detection: "system monitoring",
            captureDemandActive: true,
            windowsCapture: "capturing",
            roundTripMs: 7,
            inputConsumers: ["QuickTime Player"],
            metrics: ReceiverMetrics(
                framesReceived: 42,
                lastSequence: 41,
                bufferedMs: 60,
                targetBufferMs: 60,
                underruns: 0,
                overruns: 1,
                staleDrops: 2,
                inputLevel: 0.5,
                peakLevel: 0.8
            ),
            recentEvents: ["[12:00:00.000] Capture demand sent to Windows."]
        ).text

        XCTAssertTrue(report.contains("App version: 0.2.0 (2)"))
        XCTAssertTrue(report.contains("Driver version: 0.2.0 (2)"))
        XCTAssertTrue(report.contains("Protocol version: 3"))
        XCTAssertTrue(report.contains("Connection: Connected"))
        XCTAssertTrue(report.contains("RTT: 7 ms"))
        XCTAssertTrue(report.contains("Frames received: 42"))
        XCTAssertTrue(report.contains("Input consumers: QuickTime Player"))
        XCTAssertTrue(report.contains("Capture demand sent to Windows."))
    }

    func testReportUsesPlaceholdersWithoutConnectionMetricsOrEvents() {
        let report = ReceiverDiagnosticsSnapshot(
            appVersion: "unknown",
            driverVersion: "not installed",
            protocolVersion: 3,
            connection: "Waiting for sender",
            audioInput: "Ech0 Virtual Microphone",
            detection: "system monitoring",
            captureDemandActive: false,
            windowsCapture: "idle",
            roundTripMs: nil,
            inputConsumers: [],
            metrics: ReceiverMetrics(),
            recentEvents: []
        ).text

        XCTAssertTrue(report.contains("Driver version: not installed"))
        XCTAssertTrue(report.contains("RTT: —"))
        XCTAssertTrue(report.contains("Input consumers: none"))
        XCTAssertTrue(report.hasSuffix("No events yet"))
    }

    func testRedactorRemovesCurrentAddressAndDeviceIdentifiersFromEvents() {
        let events = [
            "[12:00:00.000] Receiver ready on 192.168.1.4:48484.",
            "[12:00:01.000] Accepted sender SE7EN-PC via trusted.",
            "[12:00:02.000] Rejected token PAIRING-SECRET.",
        ]

        let redacted = ReceiverDiagnosticsRedactor.redact(
            events,
            sensitiveValues: ["192.168.1.4", "SE7EN-PC", "PAIRING-SECRET"]
        ).joined(separator: "\n")

        XCTAssertFalse(redacted.contains("192.168.1.4"))
        XCTAssertFalse(redacted.contains("SE7EN-PC"))
        XCTAssertFalse(redacted.contains("PAIRING-SECRET"))
        XCTAssertTrue(redacted.contains("Receiver ready on <redacted>:48484."))
        XCTAssertTrue(redacted.contains("Accepted sender <redacted> via trusted."))
        XCTAssertTrue(redacted.contains("Rejected token <redacted>."))
    }
}
