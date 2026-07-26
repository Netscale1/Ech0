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

@MainActor
final class ReceiverMetricsModel: ObservableObject {
    @Published private(set) var value = ReceiverMetrics()

    func update(_ metrics: ReceiverMetrics) {
        value = metrics
    }
}

struct ReceiverPresentationPolicy {
    static func remoteCaptureState(
        current: String,
        after connectionState: ReceiverServer.ConnectionState
    ) -> String {
        switch connectionState {
        case .connected:
            return current
        case .idle, .listening, .handshaking:
            return "idle"
        }
    }
}

@MainActor
final class ReceiverViewModel: ObservableObject {
    @Published var clientName: String?
    @Published var connectionLabel = "Starting"
    @Published var errorMessage: String?
    @Published var host = LocalHostResolver.primaryIPv4Address() ?? "127.0.0.1"
    @Published var isBlackHoleAvailable = false
    @Published var logs: [String] = []
    let metrics = ReceiverMetricsModel()
    @Published var pairingCode: String
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
    private let audioFrameMetrics = AudioFrameMetricsAccumulator()
    private let trustedDeviceStore = TrustedDeviceStore()
    private let receiverIdentity: ReceiverIdentity
    private let receiverIdentityError: Error?
    private let inputDemandMonitor = AudioInputDemandMonitor()
    private let codexAccessibilityMonitor = CodexDictationAccessibilityMonitor()
    private let codexShortcutMonitor = CodexDictationShortcutMonitor()
    private let server: ReceiverServer
    private var metricsTimer: DispatchSourceTimer?
    private var captureDemandWasActive = false
    private static let logTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    init() {
        let initialPairingCode = PairingCode.generate()
        let loadedIdentity: ReceiverIdentity
        let identityError: Error?
        do {
            loadedIdentity = try ReceiverIdentityStore().loadOrCreate()
            identityError = nil
        } catch {
            loadedIdentity = ReceiverIdentity(id: "")
            identityError = error
        }
        pairingCode = initialPairingCode
        receiverIdentity = loadedIdentity
        receiverIdentityError = identityError
        server = ReceiverServer(
            port: 48_484,
            token: initialPairingCode,
            receiverId: loadedIdentity.id,
            receiverName: Host.current().localizedName ?? "Ech0 Mac",
            signingPrivateKey: loadedIdentity.signingPrivateKey
        )
        bindCallbacks()
        refreshHostAddress()
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
        metricsTimer?.cancel()
        server.stop()
        audioEngine.stop()
        inputDemandMonitor.stop()
        codexAccessibilityMonitor.stop()
        codexShortcutMonitor.stop()
    }

    func refreshHostAddress() {
        host = LocalHostResolver.primaryIPv4Address() ?? host
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
        metrics.update(ReceiverMetrics())
        clientName = nil

        if let receiverIdentityError {
            connectionLabel = "Setup required"
            errorMessage = "Receiver identity could not be persisted: \(receiverIdentityError.localizedDescription)"
            appendLog(errorMessage ?? "Receiver identity persistence failed.")
            return
        }

        guard isBlackHoleAvailable else {
            connectionLabel = "Setup required"
            appendLog("Blocked startup because \(blackHoleDeviceName) is not installed.")
            return
        }

        do {
            try synchronizeBlackHoleDevice()
            try audioEngine.prepare(deviceNamed: blackHoleDeviceName)
            try audioEngine.start()
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
        do {
            guard try trustedDeviceStore.forget(id: device.id) else { return }
            server.revokeTrustedSender(id: device.id)
            refreshTrustedDevices()
            appendLog("Forgot trusted device \(device.deviceName).")
        } catch {
            errorMessage = error.localizedDescription
            appendLog("Failed to persist trusted-device removal: \(error.localizedDescription)")
        }
    }

    var isCaptureDemandActive: Bool {
        CodexCapturePolicy.isCaptureDemandActive(
            accessibilityState: codexAccessibilityState,
            manualFallbackActive: codexShortcutCaptureActive,
            independentInputConsumerActive: inputConsumers.contains {
                !Self.isPersistentCodexConsumer($0)
            },
            automaticCapturePaused: automaticCapturePaused
        )
    }

    var canUseCodexManualFallback: Bool {
        CodexCapturePolicy.allowsManualFallback(
            accessibilityState: codexAccessibilityState,
            automaticCapturePaused: automaticCapturePaused
        )
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
        guard codexShortcutCaptureActive || canUseCodexManualFallback else { return }
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
            let update: TrustUpdate
            do {
                guard let persistedUpdate = try self.trustedDeviceStore.trust(
                    senderId: hello.senderId,
                    deviceName: hello.deviceName,
                    trustedSecret: hello.trustedSecret
                ) else {
                    return false
                }
                update = persistedUpdate
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = error.localizedDescription
                    self.appendLog("Failed to persist trusted device: \(error.localizedDescription)")
                }
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
            self.audioEngine.enqueue(frame)
            let inputLevel = Self.normalizedAudioLevel(for: frame.samples)
            let firstFrameLatency = self.audioFrameMetrics.record(
                sequence: frame.sequence,
                level: inputLevel,
                at: ProcessInfo.processInfo.systemUptime
            )
            if let firstFrameLatency {
                DispatchQueue.main.async {
                    let elapsedMs = firstFrameLatency
                    self.appendLog("First Windows audio frame received after \(elapsedMs) ms.")
                }
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
                    self.audioEngine.clear()
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
            if consumers.contains(where: Self.isPersistentCodexConsumer) {
                self.codexAccessibilityMonitor.requestPriorityRescan()
            }
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
            guard let self, self.canUseCodexManualFallback else { return }
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
        let active = isCaptureDemandActive
        if active != captureDemandWasActive {
            captureDemandWasActive = active
            if active {
                audioFrameMetrics.beginDemand(at: ProcessInfo.processInfo.systemUptime)
                do {
                    try audioEngine.start()
                } catch {
                    errorMessage = error.localizedDescription
                    appendLog("Failed to start BlackHole output: \(error.localizedDescription)")
                }
                appendLog("Capture demand sent to Windows.")
            } else {
                audioFrameMetrics.endDemand()
            }
        }
        server.updateCaptureDemand(active: active)
        if !active {
            audioEngine.clear()
        }
    }

    private func refreshLaunchAtLoginStatus() {
        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    }

    private func apply(state: ReceiverServer.ConnectionState) {
        remoteCaptureState = ReceiverPresentationPolicy.remoteCaptureState(
            current: remoteCaptureState,
            after: state
        )
        switch state {
        case .idle:
            connectionLabel = "Idle"
            clientName = nil
            connectedSenderId = nil
            audioEngine.stop()
            audioFrameMetrics.reset()
            metrics.update(ReceiverMetrics())

        case .listening:
            connectionLabel = "Waiting for sender"
            clientName = nil
            connectedSenderId = nil
            audioEngine.stop()
            do {
                try audioEngine.prepare(deviceNamed: blackHoleDeviceName)
                try audioEngine.start()
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
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25, leeway: .milliseconds(25))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshMetricsIfVisible()
            }
        }
        metricsTimer = timer
        timer.resume()
    }

    private func refreshMetricsIfVisible() {
        let snapshot = audioEngine.snapshot()
        let frameMetrics = audioFrameMetrics.snapshotAndDecay()
        guard NSApp.windows.contains(where: {
            $0.isVisible && $0.title == "Ech0" && $0.styleMask.contains(.titled)
        }) else { return }
        metrics.update(ReceiverMetrics(
            framesReceived: frameMetrics.framesReceived,
            lastSequence: frameMetrics.lastSequence,
            bufferedMs: snapshot.bufferedMs,
            targetBufferMs: snapshot.targetBufferMs,
            underruns: snapshot.underruns,
            overruns: snapshot.overruns,
            staleDrops: snapshot.staleDrops,
            inputLevel: frameMetrics.inputLevel,
            peakLevel: frameMetrics.peakLevel
        ))
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
        let stampedLine = "[\(Self.logTimeFormatter.string(from: Date()))] \(line)"
        logs.insert(stampedLine, at: 0)
        if logs.count > 10 {
            logs = Array(logs.prefix(10))
        }
    }
}
