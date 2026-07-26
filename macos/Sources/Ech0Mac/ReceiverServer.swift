import Foundation
import Network

struct ReceiverAuthenticationDecision: Equatable {
    let accepted: Bool
    let authentication: String?
    let rejectionReason: String?

    static func evaluate(
        authenticationMode: SecureHandshake.AuthenticationMode,
        tokenMatches: Bool,
        trustedIdentityMatches: Bool
    ) -> Self {
        switch authenticationMode {
        case .trusted where trustedIdentityMatches:
            return Self(accepted: true, authentication: "trusted", rejectionReason: nil)
        case .pairing where tokenMatches:
            return Self(accepted: true, authentication: "pairing", rejectionReason: nil)
        default:
            return Self(
                accepted: false,
                authentication: nil,
                rejectionReason: "pairingRequired"
            )
        }
    }
}

struct ReceiverTrustEstablishment {
    static func succeeds(
        trustedIdentityMatches: Bool,
        tokenMatches: Bool,
        pairingWasPersisted: Bool
    ) -> Bool {
        trustedIdentityMatches || (tokenMatches && pairingWasPersisted)
    }
}

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

struct ReceiverCallbackGeneration {
    static func accepts(callbackGeneration: UInt64, currentGeneration: UInt64) -> Bool {
        callbackGeneration == currentGeneration
    }
}

enum CompletionSequence {
    static func run<Item: Sendable>(
        _ items: [Item],
        at index: Int = 0,
        send: @escaping @Sendable (Item, @escaping @Sendable (Error?) -> Void) -> Void,
        completion: @escaping @Sendable (Error?) -> Void
    ) {
        guard index < items.count else {
            completion(nil)
            return
        }
        send(items[index]) { error in
            guard error == nil else {
                completion(error)
                return
            }
            run(
                items,
                at: index + 1,
                send: send,
                completion: completion
            )
        }
    }
}

struct ReceiverCaptureGate {
    static func acceptsAudio(demandActive: Bool) -> Bool {
        demandActive
    }

    static func acceptsStatus(generation: UInt64, currentGeneration: UInt64) -> Bool {
        generation == currentGeneration
    }
}

struct ReceiverProtocolSupport {
    static func rejectionReason(protocolVersion: Int, capabilities: [String]?) -> String? {
        guard protocolVersion == SecureHandshake.protocolVersion else {
            return "unsupportedProtocol"
        }
        let capabilities = capabilities ?? []
        guard capabilities.contains("remoteCaptureControl"),
              capabilities.contains(SecureHandshake.capability) else {
            return "unsupportedCapabilities"
        }
        return nil
    }
}

final class ReceiverServer: @unchecked Sendable {
    enum ConnectionState: Equatable {
        case idle
        case listening(port: UInt16)
        case handshaking
        case connected(deviceName: String, senderId: String?)
    }

    private final class ConnectionContext: @unchecked Sendable {
        let acceptedAt = ProcessInfo.processInfo.systemUptime
        let peer: String
        var didHandshake = false
        var deviceName = ""
        var senderId: String?
        var lastPingAt: TimeInterval?
        var secureSession: SecureRecordSession?
        var authenticationMode: SecureHandshake.AuthenticationMode?
        var receiverKeyHash: String?

        init(peer: String) {
            self.peer = peer
        }
    }

    private final class ReceiveBuffer: @unchecked Sendable {
        var data = Data()
    }

    var onAudioFrame: ((AudioFrame) -> Void)?
    var onLog: ((String) -> Void)?
    var onStateChange: ((ConnectionState) -> Void)?
    var authenticateTrustedSender: ((ClientHello) -> Bool)?
    var trustSenderFromPairing: ((ClientHello) -> Bool)?
    var onCaptureStatus: ((CaptureStatus) -> Void)?

    private let queue = DispatchQueue(label: "net.ech0.receiver.server")
    private let queueKey = DispatchSpecificKey<Void>()
    private let targetBufferMs: Int
    private let connectionTimeout: TimeInterval
    private let port: UInt16
    private let receiverId: String
    private let receiverName: String
    private let signingPrivateKey: Data
    private var expectedToken: String
    private var pairingAttemptLimiter = PairingAttemptLimiter()
    private var listener: NWListener?
    private var listenerGeneration: UInt64 = 0
    private var livenessTimer: DispatchSourceTimer?
    private var activeConnection: NWConnection?
    private var activeContext: ConnectionContext?
    private var captureDemandActive = false
    private var captureDemandGeneration: UInt64 = 0

    init(
        port: UInt16 = 48_484,
        token: String,
        receiverId: String,
        receiverName: String,
        signingPrivateKey: Data,
        targetBufferMs: Int = 60,
        connectionTimeout: TimeInterval = 5
    ) {
        self.port = port
        self.expectedToken = token
        self.receiverId = receiverId
        self.receiverName = receiverName
        self.signingPrivateKey = signingPrivateKey
        self.targetBufferMs = targetBufferMs
        self.connectionTimeout = connectionTimeout
        queue.setSpecific(key: queueKey, value: ())
    }

    func updateToken(_ token: String) {
        queue.async {
            self.expectedToken = token
        }
    }

    func revokeTrustedSender(id: String) {
        queue.async {
            guard
                let connection = self.activeConnection,
                let context = self.activeContext,
                context.senderId == id
            else { return }

            self.sendControlsAndDisconnect(
                [.stop(StopMessage(reason: "trustRevoked"))],
                connection: connection,
                reason: "trustRevoked"
            )
        }
    }

    func start() throws {
        try syncOnQueue {
            try startOnQueue()
        }
    }

    private func startOnQueue() throws {
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

        listenerGeneration &+= 1
        let generation = listenerGeneration
        listener = newListener
        newListener.stateUpdateHandler = { [weak self, weak newListener] state in
            guard let newListener else { return }
            self?.handleListenerState(
                state,
                listener: newListener,
                generation: generation
            )
        }
        newListener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        newListener.start(queue: queue)
        startLivenessTimer()
        onStateChange?(.listening(port: port))
        onLog?("Listening on port \(port)")
    }

    func stop() {
        syncOnQueue {
            listenerGeneration &+= 1
            livenessTimer?.cancel()
            livenessTimer = nil
            activeConnection?.stateUpdateHandler = nil
            activeConnection?.cancel()
            activeConnection = nil
            activeContext = nil
            listener?.stateUpdateHandler = nil
            listener?.newConnectionHandler = nil
            listener?.cancel()
            listener = nil
        }
        onStateChange?(.idle)
    }

    private func handleListenerState(
        _ state: NWListener.State,
        listener sourceListener: NWListener,
        generation: UInt64
    ) {
        guard
            listener === sourceListener,
            ReceiverCallbackGeneration.accepts(
                callbackGeneration: generation,
                currentGeneration: listenerGeneration
            )
        else { return }

        switch state {
        case .ready:
            onStateChange?(.listening(port: port))
        case .failed(let error):
            onLog?("Listener failed: \(error.localizedDescription)")
            listenerGeneration &+= 1
            livenessTimer?.cancel()
            livenessTimer = nil
            sourceListener.stateUpdateHandler = nil
            sourceListener.newConnectionHandler = nil
            sourceListener.cancel()
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
        let context = ConnectionContext(peer: peerIdentifier(for: connection))
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
        if let secureSession = context.secureSession {
            receiveSecureRecord(
                on: connection,
                context: context,
                secureSession: secureSession
            )
        } else {
            receivePlainPacket(on: connection, context: context)
        }
    }

    private func receivePlainPacket(on connection: NWConnection, context: ConnectionContext) {
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

    private func receiveSecureRecord(
        on connection: NWConnection,
        context: ConnectionContext,
        secureSession: SecureRecordSession
    ) {
        receiveExact(on: connection, length: SecureRecordSession.headerLength) { [weak self] result in
            guard let self else { return }
            guard self.activeConnection === connection else { return }

            switch result {
            case .failure(let error):
                self.handleDisconnect(connection: connection, reason: error.localizedDescription)

            case .success(let header):
                do {
                    let bodyLength = try secureSession.bodyLength(forHeader: header)
                    self.receiveExact(on: connection, length: bodyLength) { [weak self] result in
                        guard let self else { return }
                        guard self.activeConnection === connection else { return }

                        do {
                            let body = try result.get()
                            let packet = try secureSession.open(header + body)
                            try self.processEncodedPacket(
                                packet,
                                on: connection,
                                context: context
                            )
                            if self.activeConnection === connection {
                                self.receiveNext(on: connection, context: context)
                            }
                        } catch {
                            self.handleDisconnect(
                                connection: connection,
                                reason: error.localizedDescription
                            )
                        }
                    }
                } catch {
                    self.handleDisconnect(connection: connection, reason: error.localizedDescription)
                }
            }
        }
    }

    private func processEncodedPacket(
        _ packet: Data,
        on connection: NWConnection,
        context: ConnectionContext
    ) throws {
        guard packet.count >= 5 else {
            throw SecureTransportError.invalidRecord
        }
        let type = packet[packet.startIndex]
        let length = Int(packet.readUInt32BE(at: 1))
        guard length == packet.count - 5,
              length <= PacketCodec.maximumPayloadSize,
              type != PacketCodec.controlType || length <= PacketCodec.maximumControlPayloadSize else {
            throw SecureTransportError.invalidRecord
        }
        processPacket(
            type: type,
            payload: packet.subdata(in: 5..<packet.count),
            on: connection,
            context: context
        )
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
                guard ReceiverCaptureGate.acceptsAudio(
                    demandActive: captureDemandActive
                ) else {
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
        guard context.secureSession != nil else {
            if case .keyExchangeClientHello(let hello) = message {
                handleKeyExchange(hello, on: connection, context: context)
            } else {
                handleDisconnect(connection: connection, reason: "secureHandshakeRequired")
            }
            return
        }

        switch message {
        case .clientHello(let hello):
            guard !context.didHandshake,
                  let authenticationMode = context.authenticationMode else {
                reject(connection: connection, reason: "unexpectedClientHello")
                return
            }
            if let reason = ReceiverProtocolSupport.rejectionReason(
                protocolVersion: hello.protocolVersion,
                capabilities: hello.capabilities
            ) {
                reject(connection: connection, reason: reason)
                return
            }
            let expectedNormalizedToken = PairingCode.normalize(expectedToken)
            let presentedNormalizedToken = PairingCode.normalize(hello.token)
            let acceptedByToken: Bool
            if authenticationMode == .pairing,
               let expectedNormalizedToken,
               let presentedNormalizedToken {
                acceptedByToken = SecureHandshake.constantTimeEquals(
                    Data(expectedNormalizedToken.utf8),
                    Data(presentedNormalizedToken.utf8)
                )
            } else {
                acceptedByToken = false
            }
            let acceptedByTrustedIdentity = authenticationMode == .trusted
                && hello.token.isEmpty
                && (authenticateTrustedSender?(hello) ?? false)
            let authenticationDecision = ReceiverAuthenticationDecision.evaluate(
                authenticationMode: authenticationMode,
                tokenMatches: acceptedByToken,
                trustedIdentityMatches: acceptedByTrustedIdentity
            )
            guard authenticationDecision.accepted else {
                reject(connection: connection, reason: authenticationDecision.rejectionReason ?? "pairingRequired")
                return
            }
            guard hello.sampleRate == 48_000, hello.channels == 1, hello.frameMs == 20 else {
                reject(connection: connection, reason: "unsupportedAudioFormat")
                return
            }

            let pairingWasPersisted = acceptedByToken
                && (trustSenderFromPairing?(hello) ?? false)
            guard ReceiverTrustEstablishment.succeeds(
                trustedIdentityMatches: acceptedByTrustedIdentity,
                tokenMatches: acceptedByToken,
                pairingWasPersisted: pairingWasPersisted
            ) else {
                reject(connection: connection, reason: "trustEstablishmentFailed")
                return
            }
            if authenticationMode == .pairing {
                pairingAttemptLimiter.reset(peer: context.peer)
            }
            context.didHandshake = true
            context.lastPingAt = ProcessInfo.processInfo.systemUptime
            context.deviceName = hello.deviceName
            context.senderId = hello.senderId
            let trustEstablished = true
            let authentication = authenticationDecision.authentication ?? "pairing"
            sendControl(
                .serverHello(
                    ServerHello(
                        accepted: true,
                        reason: nil,
                        targetBufferMs: targetBufferMs,
                        negotiatedProtocolVersion: SecureHandshake.protocolVersion,
                        capabilities: ["remoteCaptureControl", SecureHandshake.capability],
                        receiverId: receiverId,
                        receiverName: receiverName,
                        receiverKeyHash: context.receiverKeyHash,
                        authentication: authentication,
                        trustEstablished: trustEstablished
                    )
                ),
                on: connection
            )
            let authMode = acceptedByTrustedIdentity ? "trusted device" : "pairing token"
            onLog?("Accepted sender \(hello.deviceName) via \(authMode).")
            onStateChange?(.connected(deviceName: hello.deviceName, senderId: hello.senderId))
            sendCurrentCaptureDemand(on: connection)

        case .ping(let ping):
            guard context.didHandshake else {
                reject(connection: connection, reason: "handshakeRequired")
                return
            }
            context.lastPingAt = ProcessInfo.processInfo.systemUptime
            sendControl(.pong(PongMessage(monotonicMs: ping.monotonicMs)), on: connection)

        case .stop(let stop):
            guard context.didHandshake else {
                reject(connection: connection, reason: "handshakeRequired")
                return
            }
            onLog?("Sender stopped session: \(stop.reason)")
            handleDisconnect(connection: connection, reason: stop.reason)

        case .captureStatus(let status):
            guard context.didHandshake else {
                reject(connection: connection, reason: "handshakeRequired")
                return
            }
            guard ReceiverCaptureGate.acceptsStatus(
                generation: status.generation,
                currentGeneration: captureDemandGeneration
            ) else { return }
            onCaptureStatus?(status)

        case .keyExchangeClientHello, .keyExchangeServerHello,
             .serverHello, .pong, .captureDemand:
            reject(connection: connection, reason: "unexpectedControlMessage")
        }
    }

    private func handleKeyExchange(
        _ hello: KeyExchangeClientHello,
        on connection: NWConnection,
        context: ConnectionContext
    ) {
        if hello.authMode == SecureHandshake.AuthenticationMode.pairing.rawValue,
           !pairingAttemptLimiter.registerAttempt(
                peer: context.peer,
                now: ProcessInfo.processInfo.systemUptime
           ) {
            sendPlainRejection(on: connection, reason: "rateLimited")
            return
        }

        do {
            let result = try SecureServerKeyExchange.accept(
                hello,
                receiverId: receiverId,
                signingPrivateKeyData: signingPrivateKey,
                pairingCode: expectedToken
            )
            context.secureSession = result.session
            context.authenticationMode = result.authenticationMode
            context.receiverKeyHash = result.receiverKeyHash
            sendPlainControl(.keyExchangeServerHello(result.response), on: connection)
        } catch {
            sendPlainRejection(on: connection, reason: "secureHandshakeRejected")
        }
    }

    private func reject(connection: NWConnection, reason: String) {
        sendControlsAndDisconnect(
            [
                .serverHello(
                ServerHello(
                        accepted: false,
                        reason: reason,
                        targetBufferMs: targetBufferMs,
                        negotiatedProtocolVersion: nil,
                        capabilities: nil,
                        receiverId: nil,
                        receiverName: nil,
                        receiverKeyHash: nil,
                        authentication: nil,
                        trustEstablished: nil
                )),
                .stop(StopMessage(reason: reason)),
            ],
            connection: connection,
            reason: reason
        )
    }

    private func sendControl(
        _ message: ControlMessage,
        on connection: NWConnection,
        completion: (@Sendable (Error?) -> Void)? = nil
    ) {
        do {
            guard activeConnection === connection,
                  let secureSession = activeContext?.secureSession else {
                throw SecureTransportError.invalidHandshake
            }
            let payload = try ControlMessageCodec.encode(message)
            let packet = PacketCodec.encodePacket(type: PacketCodec.controlType, payload: payload)
            let record = try secureSession.seal(packet)
            connection.send(content: record, completion: .contentProcessed { [weak self] error in
                if let error {
                    self?.handleDisconnect(connection: connection, reason: error.localizedDescription)
                }
                completion?(error)
            })
        } catch {
            handleDisconnect(connection: connection, reason: error.localizedDescription)
            completion?(error)
        }
    }

    private func sendPlainControl(
        _ message: ControlMessage,
        on connection: NWConnection,
        completion: (@Sendable (Error?) -> Void)? = nil
    ) {
        do {
            let payload = try ControlMessageCodec.encode(message)
            let packet = PacketCodec.encodePacket(type: PacketCodec.controlType, payload: payload)
            connection.send(content: packet, completion: .contentProcessed { [weak self] error in
                if let error {
                    self?.handleDisconnect(connection: connection, reason: error.localizedDescription)
                }
                completion?(error)
            })
        } catch {
            handleDisconnect(connection: connection, reason: error.localizedDescription)
            completion?(error)
        }
    }

    private func sendPlainRejection(on connection: NWConnection, reason: String) {
        queue.asyncAfter(deadline: .now() + 1) { [weak self, weak connection] in
            guard let connection else { return }
            self?.handleDisconnect(connection: connection, reason: reason)
        }
        sendPlainControl(
            .keyExchangeServerHello(
                KeyExchangeServerHello(
                    accepted: false,
                    reason: reason,
                    receiverId: nil,
                    serverSigningPublicKey: nil,
                    serverEphemeralPublicKey: nil,
                    serverNonce: nil,
                    signature: nil,
                    pairingProof: nil
                )
            ),
            on: connection
        ) { [weak self, weak connection] error in
            guard error == nil, let connection else { return }
            self?.handleDisconnect(connection: connection, reason: reason)
        }
    }

    private func sendControlsAndDisconnect(
        _ messages: [ControlMessage],
        connection: NWConnection,
        reason: String
    ) {
        queue.asyncAfter(deadline: .now() + 1) { [weak self, weak connection] in
            guard let connection else { return }
            self?.handleDisconnect(connection: connection, reason: reason)
        }
        CompletionSequence.run(
            messages,
            send: { [weak self, weak connection] message, completion in
                guard let self, let connection, self.activeConnection === connection else {
                    completion(ReceiverError.connectionClosed)
                    return
                }
                self.sendControl(message, on: connection, completion: completion)
            },
            completion: { [weak self, weak connection] error in
                guard error == nil, let connection else { return }
                self?.handleDisconnect(connection: connection, reason: reason)
            }
        )
    }

    func updateCaptureDemand(active: Bool) {
        queue.async {
            guard self.captureDemandActive != active else { return }
            self.captureDemandActive = active
            self.captureDemandGeneration &+= 1
            guard let connection = self.activeConnection else { return }
            self.sendCurrentCaptureDemand(on: connection)
        }
    }

    private func sendCurrentCaptureDemand(on connection: NWConnection) {
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
        completion: @escaping @Sendable (Result<Data, Error>) -> Void
    ) {
        if length == 0 {
            completion(.success(Data()))
            return
        }

        let buffer = ReceiveBuffer()

        @Sendable func step() {
            connection.receive(
                minimumIncompleteLength: 1,
                maximumLength: length - buffer.data.count
            ) { data, _, isComplete, error in
                if let error {
                    completion(.failure(error))
                    return
                }

                if let data, !data.isEmpty {
                    buffer.data.append(data)
                }

                if buffer.data.count == length {
                    completion(.success(buffer.data))
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

    private func peerIdentifier(for connection: NWConnection) -> String {
        if case .hostPort(let host, _) = connection.endpoint {
            return String(describing: host)
        }
        return String(describing: connection.endpoint)
    }

    private func syncOnQueue<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return try body()
        }
        return try queue.sync(execute: body)
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
