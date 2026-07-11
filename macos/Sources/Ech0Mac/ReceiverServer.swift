import Foundation
import Network

struct ReceiverConnectionLiveness {
    static func timeoutReason(
        didHandshake: Bool,
        acceptedAt: TimeInterval,
        lastPingAt: TimeInterval?,
        now: TimeInterval,
        timeout: TimeInterval
    ) -> String? {
        if !didHandshake {
            return now - acceptedAt > timeout ? "handshakeTimeout" : nil
        }

        guard let lastPingAt else { return "heartbeatTimeout" }
        return now - lastPingAt > timeout ? "heartbeatTimeout" : nil
    }
}

final class ReceiverServer {
    enum ConnectionState: Equatable {
        case idle
        case listening(port: UInt16)
        case handshaking
        case connected(deviceName: String)
    }

    private final class ConnectionContext {
        let acceptedAt = ProcessInfo.processInfo.systemUptime
        var didHandshake = false
        var deviceName = ""
        var protocolVersion = 1
        var supportsRemoteCaptureControl = false
        var lastPingAt: TimeInterval?
    }

    var onAudioFrame: ((AudioFrame) -> Void)?
    var onLog: ((String) -> Void)?
    var onStateChange: ((ConnectionState) -> Void)?
    var authenticateTrustedSender: ((ClientHello) -> Bool)?
    var trustSenderFromPairing: ((ClientHello) -> Void)?
    var onCaptureStatus: ((CaptureStatus) -> Void)?

    private let queue = DispatchQueue(label: "net.ech0.receiver.server")
    private let targetBufferMs: Int
    private let connectionTimeout: TimeInterval
    private let port: UInt16
    private var expectedToken: String
    private var listener: NWListener?
    private var livenessTimer: DispatchSourceTimer?
    private var activeConnection: NWConnection?
    private var activeContext: ConnectionContext?
    private var captureDemandActive = false
    private var captureDemandGeneration: UInt64 = 0

    init(
        port: UInt16 = 48_484,
        token: String,
        targetBufferMs: Int = 60,
        connectionTimeout: TimeInterval = 5
    ) {
        self.port = port
        self.expectedToken = token
        self.targetBufferMs = targetBufferMs
        self.connectionTimeout = connectionTimeout
    }

    func updateToken(_ token: String) {
        queue.async {
            self.expectedToken = token
        }
    }

    func start() throws {
        if listener != nil {
            throw ReceiverError.listenerAlreadyRunning
        }

        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw ReceiverError.listenerPortUnavailable
        }

        let newListener: NWListener
        do {
            newListener = try NWListener(using: .tcp, on: endpointPort)
        } catch {
            throw ReceiverError.listenerPortUnavailable
        }

        newListener.service = NWListener.Service(
            name: Host.current().localizedName ?? "Ech0 Mac",
            type: "_ech0._tcp"
        )

        listener = newListener
        newListener.stateUpdateHandler = { [weak self] state in
            self?.handleListenerState(state)
        }
        newListener.newConnectionHandler = { [weak self] connection in
            self?.queue.async {
                self?.accept(connection)
            }
        }
        newListener.start(queue: queue)
        startLivenessTimer()
        onStateChange?(.listening(port: port))
        onLog?("Listening on port \(port)")
    }

    func stop() {
        queue.sync {
            livenessTimer?.cancel()
            livenessTimer = nil
            activeConnection?.stateUpdateHandler = nil
            activeConnection?.cancel()
            activeConnection = nil
            activeContext = nil
            listener?.cancel()
            listener = nil
        }
        onStateChange?(.idle)
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            onStateChange?(.listening(port: port))
        case .failed(let error):
            onLog?("Listener failed: \(error.localizedDescription)")
            livenessTimer?.cancel()
            livenessTimer = nil
            listener?.cancel()
            listener = nil
            onStateChange?(.idle)
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        expireStaleConnectionIfNeeded()
        guard activeConnection == nil else {
            onLog?("Rejected additional sender while one session is active.")
            connection.cancel()
            return
        }

        activeConnection = connection
        let context = ConnectionContext()
        activeContext = context

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let connection else { return }
            self?.handleConnectionState(state, connection: connection, context: context)
        }
        connection.start(queue: queue)
    }

    private func handleConnectionState(
        _ state: NWConnection.State,
        connection: NWConnection,
        context: ConnectionContext
    ) {
        guard activeConnection === connection, activeContext === context else { return }

        switch state {
        case .ready:
            onStateChange?(.handshaking)
            onLog?("Sender TCP connection established.")
            receiveNext(on: connection, context: context)
        case .failed(let error):
            handleDisconnect(connection: connection, reason: error.localizedDescription)
        case .cancelled:
            handleDisconnect(connection: connection, reason: nil)
        default:
            break
        }
    }

    private func receiveNext(on connection: NWConnection, context: ConnectionContext) {
        receiveExact(on: connection, length: 5) { [weak self] result in
            guard let self else { return }
            guard self.activeConnection === connection else { return }

            switch result {
            case .failure(let error):
                self.handleDisconnect(connection: connection, reason: error.localizedDescription)

            case .success(let header):
                let type = header[header.startIndex]
                let length = Int(header.readUInt32BE(at: 1))

                guard length <= PacketCodec.maximumPayloadSize else {
                    self.handleDisconnect(connection: connection, reason: ReceiverError.packetTooLarge.localizedDescription)
                    return
                }
                if type == PacketCodec.controlType, length > PacketCodec.maximumControlPayloadSize {
                    self.handleDisconnect(connection: connection, reason: ReceiverError.packetTooLarge.localizedDescription)
                    return
                }

                self.receiveExact(on: connection, length: length) { [weak self] result in
                    guard let self else { return }
                    guard self.activeConnection === connection else { return }

                    switch result {
                    case .failure(let error):
                        self.handleDisconnect(connection: connection, reason: error.localizedDescription)

                    case .success(let payload):
                        self.processPacket(
                            type: type,
                            payload: payload,
                            on: connection,
                            context: context
                        )
                        if self.activeConnection === connection {
                            self.receiveNext(on: connection, context: context)
                        }
                    }
                }
            }
        }
    }

    private func processPacket(
        type: UInt8,
        payload: Data,
        on connection: NWConnection,
        context: ConnectionContext
    ) {
        do {
            switch type {
            case PacketCodec.controlType:
                let message = try ControlMessageCodec.decode(payload)
                handleControlMessage(message, on: connection, context: context)

            case PacketCodec.audioType:
                guard context.didHandshake else {
                    reject(connection: connection, reason: "audioBeforeHandshake")
                    return
                }
                let frame = try PacketCodec.decodeAudioFrame(payload)
                onAudioFrame?(frame)

            default:
                onLog?("Ignoring unknown packet type \(type).")
            }
        } catch {
            handleDisconnect(connection: connection, reason: error.localizedDescription)
        }
    }

    private func handleControlMessage(
        _ message: ControlMessage,
        on connection: NWConnection,
        context: ConnectionContext
    ) {
        switch message {
        case .clientHello(let hello):
            guard hello.protocolVersion == 1 || hello.protocolVersion == 2 else {
                reject(connection: connection, reason: "unsupportedProtocol")
                return
            }
            let acceptedByToken = hello.token == expectedToken
            let acceptedByTrustedIdentity = authenticateTrustedSender?(hello) ?? false
            guard acceptedByToken || acceptedByTrustedIdentity else {
                reject(connection: connection, reason: "invalidToken")
                return
            }
            guard hello.sampleRate == 48_000, hello.channels == 1, hello.frameMs == 20 else {
                reject(connection: connection, reason: "unsupportedAudioFormat")
                return
            }

            context.didHandshake = true
            context.lastPingAt = ProcessInfo.processInfo.systemUptime
            context.deviceName = hello.deviceName
            context.protocolVersion = hello.protocolVersion
            context.supportsRemoteCaptureControl = hello.protocolVersion >= 2
                && (hello.capabilities ?? []).contains("remoteCaptureControl")
            if acceptedByToken {
                trustSenderFromPairing?(hello)
            }
            sendControl(
                .serverHello(
                    ServerHello(
                        accepted: true,
                        reason: nil,
                        targetBufferMs: targetBufferMs,
                        negotiatedProtocolVersion: hello.protocolVersion,
                        capabilities: context.supportsRemoteCaptureControl ? ["remoteCaptureControl"] : []
                    )
                ),
                on: connection
            )
            let authMode = acceptedByTrustedIdentity && !acceptedByToken ? "trusted device" : "pairing token"
            onLog?("Accepted sender \(hello.deviceName) via \(authMode).")
            onStateChange?(.connected(deviceName: hello.deviceName))
            sendCurrentCaptureDemandIfSupported(on: connection, context: context)

        case .ping(let ping):
            context.lastPingAt = ProcessInfo.processInfo.systemUptime
            sendControl(.pong(PongMessage(monotonicMs: ping.monotonicMs)), on: connection)

        case .stop(let stop):
            onLog?("Sender stopped session: \(stop.reason)")
            handleDisconnect(connection: connection, reason: stop.reason)

        case .captureStatus(let status):
            guard context.supportsRemoteCaptureControl else { return }
            onCaptureStatus?(status)

        case .serverHello, .pong, .captureDemand:
            break
        }
    }

    private func reject(connection: NWConnection, reason: String) {
        sendControl(
            .serverHello(
                ServerHello(
                        accepted: false,
                        reason: reason,
                        targetBufferMs: targetBufferMs,
                        negotiatedProtocolVersion: nil,
                        capabilities: nil
                )
            ),
            on: connection
        )
        sendControl(.stop(StopMessage(reason: reason)), on: connection)
        queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.handleDisconnect(connection: connection, reason: reason)
        }
    }

    private func sendControl(_ message: ControlMessage, on connection: NWConnection) {
        do {
            let payload = try ControlMessageCodec.encode(message)
            let packet = PacketCodec.encodePacket(type: PacketCodec.controlType, payload: payload)
            connection.send(content: packet, completion: .contentProcessed { [weak self] error in
                if let error {
                    self?.handleDisconnect(connection: connection, reason: error.localizedDescription)
                }
            })
        } catch {
            handleDisconnect(connection: connection, reason: error.localizedDescription)
        }
    }

    func updateCaptureDemand(active: Bool) {
        queue.async {
            guard self.captureDemandActive != active else { return }
            self.captureDemandActive = active
            self.captureDemandGeneration &+= 1
            guard let connection = self.activeConnection, let context = self.activeContext else { return }
            self.sendCurrentCaptureDemandIfSupported(on: connection, context: context)
        }
    }

    private func sendCurrentCaptureDemandIfSupported(on connection: NWConnection, context: ConnectionContext) {
        guard context.supportsRemoteCaptureControl else { return }
        sendControl(
            .captureDemand(
                CaptureDemand(active: captureDemandActive, generation: captureDemandGeneration)
            ),
            on: connection
        )
    }

    private func receiveExact(
        on connection: NWConnection,
        length: Int,
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        if length == 0 {
            completion(.success(Data()))
            return
        }

        var buffer = Data()

        func step() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: length - buffer.count) { data, _, isComplete, error in
                if let error {
                    completion(.failure(error))
                    return
                }

                if let data, !data.isEmpty {
                    buffer.append(data)
                }

                if buffer.count == length {
                    completion(.success(buffer))
                    return
                }

                if isComplete {
                    completion(.failure(ReceiverError.connectionClosed))
                    return
                }

                step()
            }
        }

        step()
    }

    private func handleDisconnect(connection: NWConnection, reason: String?) {
        guard activeConnection === connection else { return }
        activeConnection = nil
        activeContext = nil
        connection.stateUpdateHandler = nil
        connection.cancel()

        if let reason, !reason.isEmpty {
            onLog?("Sender disconnected: \(reason)")
        } else {
            onLog?("Sender disconnected.")
        }

        if listener != nil {
            onStateChange?(.listening(port: port))
        } else {
            onStateChange?(.idle)
        }
    }

    private func startLivenessTimer() {
        livenessTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            self?.expireStaleConnectionIfNeeded()
        }
        livenessTimer = timer
        timer.resume()
    }

    private func expireStaleConnectionIfNeeded() {
        guard let connection = activeConnection, let context = activeContext else { return }
        let reason = ReceiverConnectionLiveness.timeoutReason(
            didHandshake: context.didHandshake,
            acceptedAt: context.acceptedAt,
            lastPingAt: context.lastPingAt,
            now: ProcessInfo.processInfo.systemUptime,
            timeout: connectionTimeout
        )
        guard let reason else { return }
        onLog?("Releasing stale sender: \(reason).")
        handleDisconnect(connection: connection, reason: reason)
    }
}

private extension Data {
    func readUInt32BE(at offset: Int) -> UInt32 {
        let slice = self[offset..<(offset + 4)]
        return slice.reduce(UInt32(0)) { partial, byte in
            (partial << 8) | UInt32(byte)
        }
    }
}
