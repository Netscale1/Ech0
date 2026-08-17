import AppKit
import SwiftUI

struct ContentView: View {
    private enum Section: String, CaseIterable, Identifiable {
        case status = "Status"
        case pairing = "Pairing"
        case diagnostics = "Diagnostics"

        var id: Self { self }
    }

    @ObservedObject var model: ReceiverViewModel
    @State private var selectedSection: Section = .status

    private let signalColor = Color(red: 0.92, green: 0.08, blue: 0.40)

    var body: some View {
        VStack(spacing: 0) {
            navigation
            Divider()

            Group {
                switch selectedSection {
                case .status:
                    statusScreen
                case .pairing:
                    pairingScreen
                case .diagnostics:
                    diagnosticsScreen
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 840, minHeight: 560)
    }

    private var navigation: some View {
        Picker("Section", selection: $selectedSection) {
            ForEach(Section.allCases) { section in
                Text(section.rawValue).tag(section)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(width: 360)
        .padding(.vertical, 14)
    }

    private var statusScreen: some View {
        ScrollView {
            VStack(spacing: 0) {
                connectionHeader
                Divider()
                routeSection
                Divider()
                statusMetrics
            }
        }
    }

    private var connectionHeader: some View {
        HStack(spacing: 14) {
            BrandMark(active: isCapturing, size: 38, accent: signalColor)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(connectionTitle)
                        .font(.title3.weight(.semibold))
                    Circle()
                        .fill(connectionColor)
                        .frame(width: 8, height: 8)
                }
                Text(connectionDetail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if model.canUseManualFallback || model.manualCaptureActive {
                Button(model.manualCaptureActive ? "Stop manual" : "Start manually") {
                    model.toggleManualCapture()
                }
                .controlSize(.large)
            }

            Button(model.automaticCapturePaused ? "Resume" : "Pause") {
                model.toggleAutomaticCapturePause()
            }
            .controlSize(.large)
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 22)
    }

    private var routeSection: some View {
        VStack(spacing: 26) {
            HStack(spacing: 18) {
                endpoint(
                    symbol: "display",
                    title: "Windows microphone",
                    detail: sourceDetail
                )

                signalLine(active: isCapturing)
                BrandMark(active: isCapturing, size: 70, accent: signalColor)
                signalLine(active: isCapturing)

                endpoint(
                    symbol: "circle.circle",
                    title: model.captureDeviceName,
                    detail: model.automaticDetectionAvailable ? "System monitoring" : "Manual fallback"
                )
            }

            levelMeter
        }
        .padding(.horizontal, 38)
        .padding(.vertical, 36)
    }

    private var statusMetrics: some View {
        ReceiverStatusMetrics(
            metrics: model.metrics,
            captureLabel: captureLabel,
            consumerCount: model.inputConsumers.count
        )
        .padding(.horizontal, 38)
        .padding(.vertical, 26)
    }

    private var pairingScreen: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 22) {
                Text("Pair a new device")
                    .font(.title2.weight(.semibold))

                Text("The code is only needed once. Trusted devices reconnect without it.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                labeledValue("Host", "\(model.host):\(model.port)", monospaced: true)

                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    labeledValue("Code for a new device", model.pairingCode, monospaced: true)
                    Button {
                        copyToPasteboard(model.pairingCode)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy pairing code")
                }

                HStack {
                    Button("New code") { model.regeneratePairingCode() }
                    Button("Refresh host") { model.refreshHostAddress() }
                }

                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(32)

            Divider()

            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Trusted devices")
                        .font(.title2.weight(.semibold))
                    Spacer()
                    Text("\(model.trustedDevices.count)/2")
                        .foregroundStyle(.secondary)
                }

                if model.trustedDevices.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "lock")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text("No trusted devices")
                            .font(.headline)
                        Text("Pair Ech0 Windows to remember this Mac securely.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 0) {
                        ForEach(model.trustedDevices) { device in
                            trustedDeviceRow(device)
                            if device.id != model.trustedDevices.last?.id {
                                Divider()
                            }
                        }
                    }
                }

                Spacer()

                Text("Only a hash of each trusted secret is stored on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(32)
        }
    }

    private var diagnosticsScreen: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 10) {
                    Circle()
                        .fill(model.errorMessage == nil ? Color.green : Color.red)
                        .frame(width: 10, height: 10)
                    Text(model.errorMessage == nil ? "No errors" : "Attention required")
                        .font(.title3.weight(.semibold))
                }

                if let errorMessage = model.errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }

                ReceiverDiagnosticsMetrics(
                    metrics: model.metrics,
                    consumerCount: model.inputConsumers.count,
                    remoteCaptureState: model.remoteCaptureState
                )

                VStack(alignment: .leading, spacing: 10) {
                    Text("Recent events")
                        .font(.headline)

                    if model.logs.isEmpty {
                        Text("No events yet")
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(model.logs.prefix(8).enumerated()), id: \.offset) { entry in
                                Text(entry.element)
                                    .font(.system(.caption, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 7)
                                if entry.offset < min(model.logs.count, 8) - 1 {
                                    Divider()
                                }
                            }
                        }
                    }
                }

                }
                .padding(32)
            }

            Divider()

            HStack {
                Button("Restart receiver") { model.restartReceiver() }
                Button("Set \(model.captureDeviceName) as input") {
                    model.setCaptureDeviceAsSystemInput()
                }
                Spacer()
                Button("Copy log") {
                    copyToPasteboard(model.logs.joined(separator: "\n"))
                }
                .disabled(model.logs.isEmpty)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 12)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(connectionColor)
                .frame(width: 8, height: 8)
            Text(lastEventSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            Toggle(
                "Launch at login",
                isOn: Binding(
                    get: { model.launchAtLoginEnabled },
                    set: { model.setLaunchAtLogin(enabled: $0) }
                )
            )
            .toggleStyle(.switch)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 13)
    }

    private var levelMeter: some View {
        ReceiverLevelMeter(metrics: model.metrics, signalColor: signalColor)
    }

    private func endpoint(symbol: String, title: String, detail: String) -> some View {
        VStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
                .frame(width: 42, height: 42)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(Circle())
            Text(title)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: 154)
    }

    private func signalLine(active: Bool) -> some View {
        Rectangle()
            .fill(active ? signalColor : Color(nsColor: .separatorColor))
            .frame(maxWidth: .infinity, minHeight: 2, maxHeight: 2)
    }

    private func labeledValue(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(value)
                .font(monospaced ? .system(.title3, design: .monospaced) : .title3)
        }
    }

    private func trustedDeviceRow(_ device: TrustedDevice) -> some View {
        HStack(spacing: 12) {
            BrandMark(active: false, size: 30, accent: signalColor)
            VStack(alignment: .leading, spacing: 3) {
                Text(device.deviceName)
                    .fontWeight(.medium)
                Text(
                    model.connectedSenderId == device.id
                        ? "Connected now"
                        : "Last seen \(device.lastSeenAt.formatted(date: .abbreviated, time: .shortened))"
                )
                    .font(.caption)
                    .foregroundStyle(model.connectedSenderId == device.id ? Color.green : Color.secondary)
            }
            Spacer()
            Button("Forget") { model.forgetTrustedDevice(device) }
        }
        .padding(.vertical, 12)
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private var isCapturing: Bool { model.remoteCaptureState == "capturing" }

    private var connectionTitle: String {
        model.clientName.map { "Connected to \($0)" } ?? model.connectionLabel
    }

    private var connectionDetail: String {
        if let errorMessage = model.errorMessage { return errorMessage }
        return model.isBlackHoleAvailable
            ? "\(model.host):\(model.port) · \(model.captureDeviceName) ready"
            : "\(model.blackHoleDeviceName) missing"
    }

    private var connectionColor: Color {
        if model.errorMessage != nil { return .red }
        if isCapturing { return signalColor }
        if model.clientName != nil { return .blue }
        return .secondary
    }

    private var sourceDetail: String {
        if model.automaticCapturePaused { return "Paused" }
        if isCapturing { return "Streaming" }
        return model.clientName ?? "Waiting"
    }

    private var captureLabel: String {
        if model.automaticCapturePaused { return "Paused" }
        if model.manualCaptureActive { return "Manual fallback" }
        if isCapturing { return "Active" }
        return model.inputConsumers.isEmpty ? "Automatic" : "Requested"
    }

    private var lastEventSummary: String {
        model.logs.first ?? "Receiver ready"
    }
}

private struct ReceiverStatusMetrics: View {
    @ObservedObject var metrics: ReceiverMetricsModel
    let captureLabel: String
    let consumerCount: Int

    var body: some View {
        HStack(alignment: .top, spacing: 34) {
            MetricColumn(rows: [
                ("Capture", captureLabel),
                ("Consumers", "\(consumerCount)"),
                ("Buffered", "\(metrics.value.bufferedMs) ms"),
            ])
            Divider()
            MetricColumn(rows: [
                ("Frames", "\(metrics.value.framesReceived)"),
                ("Underruns", "\(metrics.value.underruns)"),
                ("Overruns", "\(metrics.value.overruns)"),
            ])
        }
    }
}

private struct ReceiverDiagnosticsMetrics: View {
    @ObservedObject var metrics: ReceiverMetricsModel
    let consumerCount: Int
    let remoteCaptureState: String

    var body: some View {
        HStack(alignment: .top, spacing: 34) {
            MetricColumn(rows: [
                ("Frames received", "\(metrics.value.framesReceived)"),
                ("Buffered", "\(metrics.value.bufferedMs) ms"),
                ("Target buffer", "\(metrics.value.targetBufferMs) ms"),
                ("Underruns", "\(metrics.value.underruns)"),
                ("Overruns", "\(metrics.value.overruns)"),
            ])
            Divider()
            MetricColumn(rows: [
                ("Stale drops", "\(metrics.value.staleDrops)"),
                ("Last sequence", metrics.value.lastSequence.map(String.init) ?? "—"),
                ("Input consumers", "\(consumerCount)"),
                ("Windows capture", remoteCaptureState),
            ])
        }
    }
}

private struct ReceiverLevelMeter: View {
    @ObservedObject var metrics: ReceiverMetricsModel
    let signalColor: Color

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color(nsColor: .separatorColor))
                    Rectangle()
                        .fill(signalColor)
                        .frame(width: geometry.size.width * metrics.value.inputLevel)
                }
            }
            .frame(height: 3)

            HStack {
                Text("Input level")
                Spacer()
                Text("\(Int(metrics.value.inputLevel * 100))%")
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

private struct MetricColumn: View {
    let rows: [(String, String)]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { row in
                HStack {
                    Text(row.element.0)
                    Spacer()
                    Text(row.element.1)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .padding(.vertical, 10)
                if row.offset < rows.count - 1 {
                    Divider()
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct BrandMark: View {
    let active: Bool
    let size: CGFloat
    let accent: Color

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .renderingMode(.template)
            .interpolation(.high)
            .antialiased(true)
            .scaledToFit()
            .foregroundStyle(active ? accent : Color.primary)
            .frame(width: size, height: size)
            .accessibilityLabel(active ? "Ech0 active" : "Ech0 idle")
    }

    private var image: NSImage {
        let state = active ? "Active" : "Idle"
        let sizeSpecificName = "Ech0Brand\(state)\(Int(size))Template"
        let fallbackName = "Ech0Brand\(state)Template"
        let source = NSImage(named: NSImage.Name(sizeSpecificName))
            ?? NSImage(named: NSImage.Name(fallbackName))
            ?? NSImage(systemSymbolName: "circle", accessibilityDescription: "Ech0")!
        return source
    }
}
