import XCTest
@testable import Ech0Mac

final class ProtocolCodecTests: XCTestCase {
    func testControlMessageRoundTrip() throws {
        let message = ControlMessage.serverHello(
            ServerHello(accepted: true, reason: nil, targetBufferMs: 60)
        )

        let encoded = try ControlMessageCodec.encode(message)
        let decoded = try ControlMessageCodec.decode(encoded)

        guard case .serverHello(let value) = decoded else {
            return XCTFail("Expected serverHello")
        }

        XCTAssertTrue(value.accepted)
        XCTAssertEqual(value.targetBufferMs, 60)
    }

    func testClientHelloRoundTripWithTrustedFields() throws {
        let message = ControlMessage.clientHello(
            ClientHello(
                protocolVersion: 1,
                token: "123456",
                deviceName: "Pixel 9",
                senderId: "sender-1",
                trustedSecret: "secret-1",
                sampleRate: 48_000,
                channels: 1,
                frameMs: 20
            )
        )

        let encoded = try ControlMessageCodec.encode(message)
        let decoded = try ControlMessageCodec.decode(encoded)

        guard case .clientHello(let value) = decoded else {
            return XCTFail("Expected clientHello")
        }

        XCTAssertEqual(value.senderId, "sender-1")
        XCTAssertEqual(value.trustedSecret, "secret-1")
        XCTAssertEqual(value.sampleRate, 48_000)
    }

    func testAudioFrameRoundTrip() throws {
        let payload = PacketCodec.encodeAudioFrame(
            sequence: 7,
            captureTimestampMs: 99,
            flags: 1,
            samples: [100, -100, 200]
        )

        let frame = try PacketCodec.decodeAudioFrame(payload)
        XCTAssertEqual(frame.sequence, 7)
        XCTAssertEqual(frame.captureTimestampMs, 99)
        XCTAssertEqual(frame.flags, 1)
        XCTAssertEqual(frame.samples, [100, -100, 200])
    }
}
