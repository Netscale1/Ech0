import Foundation

private struct ControlKindProbe: Codable, Sendable {
    let kind: String
}

struct ClientHello: Codable, Sendable {
    private(set) var kind = "clientHello"
    let protocolVersion: Int
    let token: String
    let deviceName: String
    let senderId: String?
    let trustedSecret: String?
    let capabilities: [String]?
    let sampleRate: Int
    let channels: Int
    let frameMs: Int
}

struct KeyExchangeClientHello: Codable, Sendable {
    private(set) var kind = "keyExchangeClientHello"
    let protocolVersion: Int
    let authMode: String
    let clientEphemeralPublicKey: String
    let clientNonce: String
    let expectedReceiverId: String?
    let expectedReceiverKeyHash: String?
}

struct KeyExchangeServerHello: Codable, Sendable {
    private(set) var kind = "keyExchangeServerHello"
    let accepted: Bool
    let reason: String?
    let receiverId: String?
    let serverSigningPublicKey: String?
    let serverEphemeralPublicKey: String?
    let serverNonce: String?
    let signature: String?
    let pairingProof: String?
}

struct ServerHello: Codable, Sendable {
    private(set) var kind = "serverHello"
    let accepted: Bool
    let reason: String?
    let targetBufferMs: Int
    let negotiatedProtocolVersion: Int?
    let capabilities: [String]?
    let receiverId: String?
    let receiverName: String?
    let receiverKeyHash: String?
    let authentication: String?
    let trustEstablished: Bool?
}

struct CaptureDemand: Codable, Sendable {
    private(set) var kind = "captureDemand"
    let active: Bool
    let generation: UInt64
}

struct CaptureStatus: Codable, Sendable {
    private(set) var kind = "captureStatus"
    let generation: UInt64
    let state: String
    let errorCode: String?
}

struct PingMessage: Codable, Sendable {
    private(set) var kind = "ping"
    let monotonicMs: UInt64
}

struct PongMessage: Codable, Sendable {
    private(set) var kind = "pong"
    let monotonicMs: UInt64
}

struct StopMessage: Codable, Sendable {
    private(set) var kind = "stop"
    let reason: String
}

enum ControlMessage: Sendable {
    case keyExchangeClientHello(KeyExchangeClientHello)
    case keyExchangeServerHello(KeyExchangeServerHello)
    case clientHello(ClientHello)
    case serverHello(ServerHello)
    case ping(PingMessage)
    case pong(PongMessage)
    case stop(StopMessage)
    case captureDemand(CaptureDemand)
    case captureStatus(CaptureStatus)
}

enum ControlMessageCodec {
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    static func encode(_ message: ControlMessage) throws -> Data {
        switch message {
        case .keyExchangeClientHello(let value):
            return try encoder.encode(value)
        case .keyExchangeServerHello(let value):
            return try encoder.encode(value)
        case .clientHello(let value):
            return try encoder.encode(value)
        case .serverHello(let value):
            return try encoder.encode(value)
        case .ping(let value):
            return try encoder.encode(value)
        case .pong(let value):
            return try encoder.encode(value)
        case .stop(let value):
            return try encoder.encode(value)
        case .captureDemand(let value):
            return try encoder.encode(value)
        case .captureStatus(let value):
            return try encoder.encode(value)
        }
    }

    static func decode(_ data: Data) throws -> ControlMessage {
        let probe = try decoder.decode(ControlKindProbe.self, from: data)
        switch probe.kind {
        case "keyExchangeClientHello":
            return .keyExchangeClientHello(
                try decoder.decode(KeyExchangeClientHello.self, from: data)
            )
        case "keyExchangeServerHello":
            return .keyExchangeServerHello(
                try decoder.decode(KeyExchangeServerHello.self, from: data)
            )
        case "clientHello":
            return .clientHello(try decoder.decode(ClientHello.self, from: data))
        case "serverHello":
            return .serverHello(try decoder.decode(ServerHello.self, from: data))
        case "ping":
            return .ping(try decoder.decode(PingMessage.self, from: data))
        case "pong":
            return .pong(try decoder.decode(PongMessage.self, from: data))
        case "stop":
            return .stop(try decoder.decode(StopMessage.self, from: data))
        case "captureDemand":
            return .captureDemand(try decoder.decode(CaptureDemand.self, from: data))
        case "captureStatus":
            return .captureStatus(try decoder.decode(CaptureStatus.self, from: data))
        default:
            throw ReceiverError.unsupportedControlMessage(probe.kind)
        }
    }
}
