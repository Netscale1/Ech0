import SwiftUI

struct ContentView: View {
    @ObservedObject var model: ReceiverViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                heroCard
                HStack(alignment: .top, spacing: 20) {
                    pairingCard
                    statusCard
                }
                setupCard
                logsCard
            }
            .padding(24)
        }
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.95, green: 0.92, blue: 0.86),
                    Color(red: 0.84, green: 0.90, blue: 0.92),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .frame(minWidth: 960, minHeight: 720)
    }

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ech0 Receiver")
                .font(.system(size: 34, weight: .bold, design: .rounded))
            Text("Receive your Android microphone over local Wi-Fi and route it into BlackHole 2ch.")
                .font(.headline)
            HStack(spacing: 12) {
                statusPill(title: model.connectionLabel, tint: .blue)
                statusPill(
                    title: model.isBlackHoleAvailable ? "BlackHole Ready" : "BlackHole Missing",
                    tint: model.isBlackHoleAvailable ? .green : .orange
                )
                if let clientName = model.clientName {
                    statusPill(title: clientName, tint: .purple)
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(red: 0.10, green: 0.22, blue: 0.28))
        .foregroundStyle(.white)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private var pairingCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Pairing")
                .font(.title2.weight(.semibold))
            Text("Host: \(model.host):\(model.port)")
                .font(.headline)
            Text("Code: \(model.pairingCode)")
                .font(.system(size: 30, weight: .bold, design: .monospaced))

            Group {
                if let qrImage = model.qrImage {
                    Image(nsImage: qrImage)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 220, height: 220)
                        .padding(10)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.white.opacity(0.8))
                        .frame(width: 220, height: 220)
                        .overlay(Text("QR unavailable"))
                }
            }

            HStack {
                Button("Regenerate Code") {
                    model.regeneratePairingCode()
                }
                Button("Refresh Host") {
                    model.refreshHostAddress()
                }
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.92))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Receiver Status")
                .font(.title2.weight(.semibold))

            metricRow(label: "Frames received", value: "\(model.metrics.framesReceived)")
            metricRow(label: "Buffered", value: "\(model.metrics.bufferedMs) ms")
            metricRow(label: "Target buffer", value: "\(model.metrics.targetBufferMs) ms")
            metricRow(label: "Underruns", value: "\(model.metrics.underruns)")
            metricRow(label: "Overruns", value: "\(model.metrics.overruns)")
            metricRow(label: "Stale drops", value: "\(model.metrics.staleDrops)")
            metricRow(
                label: "Last sequence",
                value: model.metrics.lastSequence.map(String.init) ?? "n/a"
            )

            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Restart Receiver") {
                    model.restartReceiver()
                }
                Button("Set BlackHole as Input") {
                    model.setBlackHoleAsSystemInput()
                }
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.92))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("BlackHole Checklist")
                .font(.title3.weight(.semibold))
            Text("1. Install BlackHole 2ch.")
            Text("2. Confirm it appears in Audio MIDI Setup.")
            Text("3. Start Ech0 Receiver and let the Android app connect.")
            Text("4. In Zoom, Meet, or Discord, select BlackHole 2ch as the microphone.")
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(red: 0.98, green: 0.97, blue: 0.94))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var logsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent Events")
                .font(.title3.weight(.semibold))
            if model.logs.isEmpty {
                Text("No events yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(model.logs.enumerated()), id: \.offset) { entry in
                    Text(entry.element)
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.92))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func metricRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .fontWeight(.medium)
        }
    }

    private func statusPill(title: String, tint: Color) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(tint.opacity(0.22))
            .clipShape(Capsule())
    }
}
