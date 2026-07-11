import AppKit
import Combine
import Foundation
import ServiceManagement

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
    @Published private(set) var connectedSenderId: String?
    @Published private(set) var inputConsumers: [String] = []
    @Published private(set) var remoteCaptureState = "idle"
    @Published private(set) var codexShortcutCaptureActive = false
    @Published private(set) var codexAccessibilityState: CodexDictationAccessibilityState = .unavailable
    @Published var automaticCapturePaused = false {
        didSet { updateCaptureDemand() }
    }
    @Published private(set) var automaticDetectionAvailable = true
    @Published private(set) var launchAtLoginEnabled = false

    let blackHoleDeviceName = "BlackHole 2ch"
    let targetSampleRate = 48_000.0
    let port: UInt16 = 48_484

    private let audioEngine = AudioOutputEngine()
    private let trustedDeviceStore = TrustedDeviceStore()
    private let receiverIdentity = ReceiverIdentityStore().loadOrCreate()
    private let inputDemandMonitor = AudioInputDemandMonitor()
    private let codexAccessibilityMonitor = CodexDictationAccessibilityMonitor()
    private let codexShortcutMonitor = CodexDictationShortcutMonitor()
    private lazy var server = ReceiverServer(
        port: port,
        token: pairingCode,
        receiverId: receiverIdentity.id,
        receiverName: Host.current().localizedName ?? "Ech0 Mac"
    )
    private var metricsTimer: Timer?

    init() {
        bindCallbacks()
        refreshHostAddress()
        refreshPairingAssets()
        refreshTrustedDevices()
        refreshBlackHoleStatus()
        startMetricsTimer()
        restartReceiver()
        bindInputDemandMonitor()
        automaticDetectionAvailable = inputDemandMonitor.start(deviceNamed: blackHoleDeviceName)
        bindCodexAccessibilityMonitor()
        codexAccessibilityMonitor.start()
        bindCodexShortcutMonitor()
        codexShortcutMonitor.start()
        refreshLaunchAtLoginStatus()
    }

    deinit {
        metricsTimer?.invalidate()
        server.stop()
        audioEngine.stop()
        inputDemandMonitor.stop()
        codexAccessibilityMonitor.stop()
        codexShortcutMonitor.stop()
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
        appendLog("Generated a new pairing code.")
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
        server.revokeTrustedSender(id: device.id)
        refreshTrustedDevices()
        appendLog("Forgot trusted device \(device.deviceName).")
    }

    var isCaptureDemandActive: Bool {
        guard !automaticCapturePaused else { return false }
        return codexAccessibilityState.isActive
            || codexShortcutCaptureActive
            || inputConsumers.contains { !Self.isPersistentCodexConsumer($0) }
    }

    var isWaitingForCodexDictation: Bool {
        !automaticCapturePaused
            && !codexAccessibilityState.isActive
            && !codexShortcutCaptureActive
            && inputConsumers.contains(where: Self.isPersistentCodexConsumer)
            && !inputConsumers.contains { !Self.isPersistentCodexConsumer($0) }
    }

    var menuBarSymbolName: String {
        if errorMessage != nil || remoteCaptureState == "error" { return "exclamationmark.triangle" }
        if remoteCaptureState == "capturing" { return "mic.fill" }
        if isCaptureDemandActive { return "mic" }
        return "mic.slash"
    }

    var menuBarImageName: String {
        remoteCaptureState == "capturing"
            ? "Ech0StatusActiveTemplate"
            : "Ech0StatusIdleTemplate"
    }

    func toggleAutomaticCapturePause() {
        automaticCapturePaused.toggle()
        if automaticCapturePaused {
            codexShortcutCaptureActive = false
        }
    }

    func toggleCodexShortcutCapture() {
        guard !automaticCapturePaused else { return }
        codexShortcutCaptureActive.toggle()
        appendLog(codexShortcutCaptureActive ? "Codex dictation requested." : "Codex dictation ended.")
        updateCaptureDemand()
    }

    func openAccessibilitySettings() {
        codexAccessibilityMonitor.requestPermission()
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    func setLaunchAtLogin(enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            refreshLaunchAtLoginStatus()
        } catch {
            errorMessage = error.localizedDescription
            appendLog("Failed to update launch at login: \(error.localizedDescription)")
            refreshLaunchAtLoginStatus()
        }
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
            guard let self else { return false }
            guard let update = self.trustedDeviceStore.trust(
                senderId: hello.senderId,
                deviceName: hello.deviceName,
                trustedSecret: hello.trustedSecret
            ) else {
                return false
            }
            DispatchQueue.main.async {
                self.refreshTrustedDevices()
                if let evicted = update.evicted {
                    self.appendLog("Trusted device limit reached. Replaced \(evicted.deviceName).")
                }
                let action = update.wasNew ? "Remembered" : "Updated"
                self.appendLog("\(action) trusted device \(update.device.deviceName).")
            }
            return true
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

        server.onCaptureStatus = { [weak self] status in
            DispatchQueue.main.async {
                guard let self else { return }
                self.remoteCaptureState = status.state
                if status.state == "idle" || status.state == "paused" {
                    self.audioEngine.suspend()
                }
                if let errorCode = status.errorCode {
                    self.appendLog("Windows capture error: \(errorCode)")
                }
            }
        }
    }

    private func bindInputDemandMonitor() {
        inputDemandMonitor.onConsumersChanged = { [weak self] consumers in
            guard let self else { return }
            self.inputConsumers = consumers
            self.appendLog(
                consumers.isEmpty
                    ? "No application is using BlackHole input."
                    : "BlackHole input requested by \(consumers.joined(separator: ", "))."
            )
            self.updateCaptureDemand()
        }
        inputDemandMonitor.onUnavailable = { [weak self] in
            DispatchQueue.main.async {
                self?.automaticDetectionAvailable = false
                self?.appendLog("Per-process Core Audio monitoring is unavailable.")
            }
        }
    }

    private func bindCodexShortcutMonitor() {
        codexShortcutMonitor.onToggle = { [weak self] in
            guard let self, !self.codexAccessibilityState.isAvailable else { return }
            self.toggleCodexShortcutCapture()
        }
    }

    private func bindCodexAccessibilityMonitor() {
        codexAccessibilityMonitor.onStateChanged = { [weak self] state in
            guard let self else { return }
            let wasActive = self.codexAccessibilityState.isActive
            self.codexAccessibilityState = state
            if state.isAvailable {
                self.codexShortcutCaptureActive = false
            }

            if state.isActive != wasActive {
                self.appendLog(
                    state.isActive
                        ? "Codex dictation detected."
                        : "Codex dictation ended."
                )
            } else if state == .permissionRequired {
                self.appendLog("Accessibility access is required for automatic Codex detection.")
            }
            self.updateCaptureDemand()
        }
    }

    private func updateCaptureDemand() {
        server.updateCaptureDemand(active: isCaptureDemandActive)
        if !isCaptureDemandActive {
            audioEngine.suspend()
        }
    }

    private func refreshLaunchAtLoginStatus() {
        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    }

    private func apply(state: ReceiverServer.ConnectionState) {
        switch state {
        case .idle:
            connectionLabel = "Idle"
            clientName = nil
            connectedSenderId = nil
            audioEngine.stop()
            metrics = ReceiverMetrics()

        case .listening:
            connectionLabel = "Waiting for sender"
            clientName = nil
            connectedSenderId = nil
            audioEngine.stop()
            do {
                try audioEngine.prepare(deviceNamed: blackHoleDeviceName)
            } catch {
                errorMessage = error.localizedDescription
            }

        case .handshaking:
            connectionLabel = "Validating sender"
            clientName = nil
            connectedSenderId = nil

        case .connected(let deviceName, let senderId):
            connectionLabel = remoteCaptureState == "capturing" ? "Streaming" : "Connected"
            clientName = deviceName
            connectedSenderId = senderId
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

    private static func isPersistentCodexConsumer(_ label: String) -> Bool {
        label == "com.openai.codex.helper"
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
