import Foundation

private struct ControlKindProbe: Codable {
    let kind: String
}

struct ClientHello: Codable {
    let kind = "clientHello"
    let protocolVersion: Int
    let token: String
    let deviceName: String
    let sampleRate: Int
    let channels: Int
    let frameMs: Int
}

struct ServerHello: Codable {
    let kind = "serverHello"
    let accepted: Bool
    let reason: String?
    let targetBufferMs: Int
}

struct PingMessage: Codable {
    let kind = "ping"
    let monotonicMs: UInt64
}

struct PongMessage: Codable {
    let kind = "pong"
    let monotonicMs: UInt64
}

struct StopMessage: Codable {
    let kind = "stop"
    let reason: String
}

enum ControlMessage {
    case clientHello(ClientHello)
    case serverHello(ServerHello)
    case ping(PingMessage)
    case pong(PongMessage)
    case stop(StopMessage)
}

enum ControlMessageCodec {
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    static func encode(_ message: ControlMessage) throws -> Data {
        switch message {
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
        }
    }

    static func decode(_ data: Data) throws -> ControlMessage {
        let probe = try decoder.decode(ControlKindProbe.self, from: data)
        switch probe.kind {
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
        default:
            throw ReceiverError.unsupportedControlMessage(probe.kind)
        }
    }
}

