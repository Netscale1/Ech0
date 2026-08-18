import Foundation

struct ReceiverDiagnosticsSnapshot {
    let appVersion: String
    let driverVersion: String
    let protocolVersion: Int
    let connection: String
    let audioInput: String
    let detection: String
    let captureDemandActive: Bool
    let windowsCapture: String
    let roundTripMs: Int?
    let inputConsumers: [String]
    let metrics: ReceiverMetrics
    let recentEvents: [String]

    var text: String {
        var lines = [
            "Ech0 diagnostics",
            "App version: \(appVersion)",
            "Driver version: \(driverVersion)",
            "Protocol version: \(protocolVersion)",
            "Connection: \(connection)",
            "Audio input: \(audioInput)",
            "Detection: \(detection)",
            "Capture demand: \(captureDemandActive ? "active" : "inactive")",
            "Windows capture: \(windowsCapture)",
            "RTT: \(roundTripMs.map { "\($0) ms" } ?? "—")",
            "Frames received: \(metrics.framesReceived)",
            "Last sequence: \(metrics.lastSequence.map(String.init) ?? "—")",
            "Buffered: \(metrics.bufferedMs) ms",
            "Target buffer: \(metrics.targetBufferMs) ms",
            "Underruns: \(metrics.underruns)",
            "Overruns: \(metrics.overruns)",
            "Stale drops: \(metrics.staleDrops)",
            "Input consumers: \(inputConsumers.isEmpty ? "none" : inputConsumers.joined(separator: ", "))",
        ]
        lines.append("")
        lines.append("Recent events")
        lines.append(contentsOf: recentEvents.isEmpty ? ["No events yet"] : recentEvents)
        return lines.joined(separator: "\n")
    }
}

enum ReceiverDiagnosticsRedactor {
    static func redact(_ events: [String], sensitiveValues: [String]) -> [String] {
        events.map { event in
            sensitiveValues.reduce(event) { redacted, value in
                guard !value.isEmpty else { return redacted }
                return redacted.replacingOccurrences(of: value, with: "<redacted>")
            }
        }
    }
}
