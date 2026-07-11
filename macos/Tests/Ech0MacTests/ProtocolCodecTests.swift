import XCTest
@testable import Ech0Mac

final class ProtocolCodecTests: XCTestCase {
    func testControlMessageRoundTrip() throws {
        let message = ControlMessage.serverHello(
            ServerHello(
                accepted: true,
                reason: nil,
                targetBufferMs: 60,
                negotiatedProtocolVersion: 2,
                capabilities: ["remoteCaptureControl"],
                receiverId: "receiver-1",
                receiverName: "Mac mini",
                authentication: "trusted",
                trustEstablished: true
            )
        )

        let encoded = try ControlMessageCodec.encode(message)
        let decoded = try ControlMessageCodec.decode(encoded)

        guard case .serverHello(let value) = decoded else {
            return XCTFail("Expected serverHello")
        }

        XCTAssertTrue(value.accepted)
        XCTAssertEqual(value.targetBufferMs, 60)
        XCTAssertEqual(value.receiverId, "receiver-1")
        XCTAssertEqual(value.authentication, "trusted")
        XCTAssertEqual(value.trustEstablished, true)
    }

    func testClientHelloRoundTripWithTrustedFields() throws {
        let message = ControlMessage.clientHello(
            ClientHello(
                protocolVersion: 1,
                token: "123456",
                deviceName: "Pixel 9",
                senderId: "sender-1",
                trustedSecret: "secret-1",
                capabilities: nil,
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
            samples: Array(repeating: 100, count: PacketCodec.audioSamplesPerFrame)
        )

        let frame = try PacketCodec.decodeAudioFrame(payload)
        XCTAssertEqual(frame.sequence, 7)
        XCTAssertEqual(frame.captureTimestampMs, 99)
        XCTAssertEqual(frame.flags, 1)
        XCTAssertEqual(frame.samples.count, PacketCodec.audioSamplesPerFrame)
        XCTAssertEqual(frame.samples.first, 100)
    }

    func testCaptureDemandRoundTrip() throws {
        let encoded = try ControlMessageCodec.encode(
            .captureDemand(CaptureDemand(active: true, generation: 4))
        )
        guard case .captureDemand(let demand) = try ControlMessageCodec.decode(encoded) else {
            return XCTFail("Expected captureDemand")
        }
        XCTAssertTrue(demand.active)
        XCTAssertEqual(demand.generation, 4)
    }

    func testRejectsUnexpectedAudioFrameSize() {
        XCTAssertThrowsError(try PacketCodec.decodeAudioFrame(Data(repeating: 0, count: 22)))
    }
}
