import AppKit
import Combine
import Foundation

struct ReceiverMetrics {
    var framesReceived = 0
    var lastSequence: UInt64?
    var bufferedMs = 0
    var targetBufferMs = 60
    var underruns = 0
    var overruns = 0
    var staleDrops = 0
    var inputLevel = 0.0
    var peakLevel = 0.0
}

final class ReceiverViewModel: ObservableObject {
    @Published var clientName: String?
    @Published var connectionLabel = "Starting"
    @Published var errorMessage: String?
    @Published var host = LocalHostResolver.primaryIPv4Address() ?? "127.0.0.1"
    @Published var isBlackHoleAvailable = false
    @Published var logs: [String] = []
    @Published var metrics = ReceiverMetrics()
    @Published var pairingCode = PairingCode.generate()
    @Published private(set) var qrImage: NSImage?
    @Published private(set) var trustedDevices: [TrustedDevice] = []

    let blackHoleDeviceName = "BlackHole 2ch"
    let targetSampleRate = 48_000.0
    let port: UInt16 = 48_484

    private let audioEngine = AudioOutputEngine()
    private let trustedDeviceStore = TrustedDeviceStore()
    private lazy var server = ReceiverServer(port: port, token: pairingCode)
    private var metricsTimer: Timer?

    init() {
        bindCallbacks()
        refreshHostAddress()
        refreshPairingAssets()
        refreshTrustedDevices()
        refreshBlackHoleStatus()
        startMetricsTimer()
        restartReceiver()
    }

    deinit {
        metricsTimer?.invalidate()
        server.stop()
        audioEngine.stop()
    }

    var pairingPayload: PairingPayload {
        PairingPayload(v: 1, host: host, port: Int(port), token: pairingCode)
    }

    func refreshHostAddress() {
        host = LocalHostResolver.primaryIPv4Address() ?? host
        refreshPairingAssets()
    }

    func refreshBlackHoleStatus() {
        isBlackHoleAvailable = SystemAudio.deviceNamed(blackHoleDeviceName) != nil
        if !isBlackHoleAvailable {
            errorMessage = "\(blackHoleDeviceName) is missing. Install it before starting the receiver."
        }
    }

    func restartReceiver() {
        refreshHostAddress()
        refreshBlackHoleStatus()

        server.stop()
        audioEngine.stop()
        metrics = ReceiverMetrics()
        clientName = nil

        guard isBlackHoleAvailable else {
            connectionLabel = "Setup required"
            appendLog("Blocked startup because \(blackHoleDeviceName) is not installed.")
            return
        }

        do {
            try synchronizeBlackHoleDevice()
            try audioEngine.prepare(deviceNamed: blackHoleDeviceName)
            try server.start()
            connectionLabel = "Waiting for sender"
            errorMessage = nil
            appendLog("Receiver ready on \(host):\(port).")
        } catch {
            connectionLabel = "Setup required"
            errorMessage = error.localizedDescription
            appendLog("Failed to start receiver: \(error.localizedDescription)")
        }
    }

    func regeneratePairingCode() {
        pairingCode = PairingCode.generate()
        refreshPairingAssets()
        server.updateToken(pairingCode)
        appendLog("Generated new pairing code \(pairingCode).")
    }

    func setBlackHoleAsSystemInput() {
        do {
            try synchronizeBlackHoleDevice()
            try SystemAudio.setDefaultInputDevice(named: blackHoleDeviceName)
            appendLog("Set \(blackHoleDeviceName) as the default system input.")
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            appendLog("Failed to set default input: \(error.localizedDescription)")
        }
    }

    func forgetTrustedDevice(_ device: TrustedDevice) {
        guard trustedDeviceStore.forget(id: device.id) else { return }
        refreshTrustedDevices()
        appendLog("Forgot trusted device \(device.deviceName).")
    }

    private func bindCallbacks() {
        server.authenticateTrustedSender = { [weak self] hello in
            guard let self else { return false }
            let accepted = self.trustedDeviceStore.validate(
                senderId: hello.senderId,
                trustedSecret: hello.trustedSecret
            )
            if accepted {
                DispatchQueue.main.async {
                    self.refreshTrustedDevices()
                }
            }
            return accepted
        }

        server.trustSenderFromPairing = { [weak self] hello in
            guard let self else { return }
            guard let update = self.trustedDeviceStore.trust(
                senderId: hello.senderId,
                deviceName: hello.deviceName,
                trustedSecret: hello.trustedSecret
            ) else {
                return
            }
            DispatchQueue.main.async {
                self.refreshTrustedDevices()
                if let evicted = update.evicted {
                    self.appendLog("Trusted device limit reached. Replaced \(evicted.deviceName).")
                }
                let action = update.wasNew ? "Remembered" : "Updated"
                self.appendLog("\(action) trusted device \(update.device.deviceName).")
            }
        }

        server.onAudioFrame = { [weak self] frame in
            guard let self else { return }
            if !self.audioEngine.isRunning {
                try? self.audioEngine.start()
            }
            self.audioEngine.enqueue(frame)
            let inputLevel = Self.normalizedAudioLevel(for: frame.samples)
            DispatchQueue.main.async {
                self.metrics.framesReceived += 1
                self.metrics.lastSequence = frame.sequence
                self.metrics.inputLevel = max(inputLevel, self.metrics.inputLevel * 0.7)
                self.metrics.peakLevel = max(inputLevel, self.metrics.peakLevel * 0.96)
            }
        }

        server.onLog = { [weak self] line in
            DispatchQueue.main.async {
                self?.appendLog(line)
            }
        }

        server.onStateChange = { [weak self] state in
            DispatchQueue.main.async {
                self?.apply(state: state)
            }
        }
    }

    private func apply(state: ReceiverServer.ConnectionState) {
        switch state {
        case .idle:
            connectionLabel = "Idle"
            clientName = nil
            audioEngine.stop()
            metrics = ReceiverMetrics()

        case .listening:
            connectionLabel = "Waiting for sender"
            clientName = nil
            audioEngine.stop()
            do {
                try audioEngine.prepare(deviceNamed: blackHoleDeviceName)
            } catch {
                errorMessage = error.localizedDescription
            }

        case .handshaking:
            connectionLabel = "Validating sender"
            clientName = nil

        case .connected(let deviceName):
            connectionLabel = "Streaming"
            clientName = deviceName
        }
    }

    private func startMetricsTimer() {
        metricsTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            let snapshot = audioEngine.snapshot()
            self.metrics.bufferedMs = snapshot.bufferedMs
            self.metrics.targetBufferMs = snapshot.targetBufferMs
            self.metrics.underruns = snapshot.underruns
            self.metrics.overruns = snapshot.overruns
            self.metrics.staleDrops = snapshot.staleDrops
            self.metrics.inputLevel *= 0.55
            self.metrics.peakLevel *= 0.92
        }
        if let metricsTimer {
            RunLoop.main.add(metricsTimer, forMode: .common)
        }
    }

    private func refreshPairingAssets() {
        qrImage = QRCodeRenderer.makeImage(from: pairingPayload.jsonString)
    }

    private func refreshTrustedDevices() {
        trustedDevices = trustedDeviceStore.allDevices()
    }

    private func synchronizeBlackHoleDevice() throws {
        try SystemAudio.setNominalSampleRate(named: blackHoleDeviceName, sampleRate: targetSampleRate)
        let activeRate = try SystemAudio.nominalSampleRate(named: blackHoleDeviceName)
        appendLog("Configured \(blackHoleDeviceName) at \(Int(activeRate)) Hz.")
    }

    private static func normalizedAudioLevel(for samples: [Int16]) -> Double {
        guard !samples.isEmpty else { return 0 }

        let sumOfSquares = samples.reduce(into: 0.0) { partial, sample in
            let normalized = Double(sample) / Double(Int16.max)
            partial += normalized * normalized
        }
        let rms = sqrt(sumOfSquares / Double(samples.count))
        return min(1, rms * 4)
    }

    private func appendLog(_ line: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let stampedLine = "[\(formatter.string(from: Date()))] \(line)"
        logs.insert(stampedLine, at: 0)
        if logs.count > 10 {
            logs = Array(logs.prefix(10))
        }
    }
}
