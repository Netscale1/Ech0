import Foundation
import Network

final class ReceiverServer {
    enum ConnectionState: Equatable {
        case idle
        case listening(port: UInt16)
        case handshaking
        case connected(deviceName: String)
    }

    private final class ConnectionContext {
        var didHandshake = false
        var deviceName = ""
    }

    var onAudioFrame: ((AudioFrame) -> Void)?
    var onLog: ((String) -> Void)?
    var onStateChange: ((ConnectionState) -> Void)?

    private let queue = DispatchQueue(label: "net.ech0.receiver.server")
    private let targetBufferMs: Int
    private let port: UInt16
    private var expectedToken: String
    private var listener: NWListener?
    private var activeConnection: NWConnection?

    init(port: UInt16 = 48_484, token: String, targetBufferMs: Int = 60) {
        self.port = port
        self.expectedToken = token
        self.targetBufferMs = targetBufferMs
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
        onStateChange?(.listening(port: port))
        onLog?("Listening on port \(port)")
    }

    func stop() {
        queue.sync {
            activeConnection?.cancel()
            activeConnection = nil
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
            listener?.cancel()
            listener = nil
            onStateChange?(.idle)
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        guard activeConnection == nil else {
            onLog?("Rejected additional sender while one session is active.")
            connection.cancel()
            return
        }

        activeConnection = connection
        let context = ConnectionContext()

        connection.stateUpdateHandler = { [weak self] state in
            self?.handleConnectionState(state, context: context)
        }
        connection.start(queue: queue)
    }

    private func handleConnectionState(_ state: NWConnection.State, context: ConnectionContext) {
        guard let connection = activeConnection else { return }

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
            guard hello.protocolVersion == 1 else {
                reject(connection: connection, reason: "unsupportedProtocol")
                return
            }
            guard hello.token == expectedToken else {
                reject(connection: connection, reason: "invalidToken")
                return
            }
            guard hello.sampleRate == 48_000, hello.channels == 1, hello.frameMs == 20 else {
                reject(connection: connection, reason: "unsupportedAudioFormat")
                return
            }

            context.didHandshake = true
            context.deviceName = hello.deviceName
            sendControl(
                .serverHello(
                    ServerHello(
                        accepted: true,
                        reason: nil,
                        targetBufferMs: targetBufferMs
                    )
                ),
                on: connection
            )
            onLog?("Accepted sender \(hello.deviceName).")
            onStateChange?(.connected(deviceName: hello.deviceName))

        case .ping(let ping):
            sendControl(.pong(PongMessage(monotonicMs: ping.monotonicMs)), on: connection)

        case .stop(let stop):
            onLog?("Sender stopped session: \(stop.reason)")
            handleDisconnect(connection: connection, reason: stop.reason)

        case .serverHello, .pong:
            break
        }
    }

    private func reject(connection: NWConnection, reason: String) {
        sendControl(
            .serverHello(
                ServerHello(
                    accepted: false,
                    reason: reason,
                    targetBufferMs: targetBufferMs
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
}

private extension Data {
    func readUInt32BE(at offset: Int) -> UInt32 {
        let slice = self[offset..<(offset + 4)]
        return slice.reduce(UInt32(0)) { partial, byte in
            (partial << 8) | UInt32(byte)
        }
    }
}
