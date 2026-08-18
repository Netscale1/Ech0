import XCTest
@testable import Ech0Mac

final class ProtocolCodecTests: XCTestCase {
    func testControlMessageRoundTrip() throws {
        let message = ControlMessage.serverHello(
            ServerHello(
                accepted: true,
                reason: nil,
                targetBufferMs: 60,
                negotiatedProtocolVersion: 3,
                capabilities: ["remoteCaptureControl", "secureTransportV3"],
                receiverId: "receiver-1",
                receiverName: "Mac mini",
                receiverKeyHash: "key-hash",
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
                protocolVersion: 3,
                token: PairingCode.generate(),
                deviceName: "Windows PC",
                senderId: "sender-1",
                trustedSecret: "secret-1",
                capabilities: ["remoteCaptureControl", "secureTransportV3"],
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

    func testPingRoundTripIncludesReportedRTT() throws {
        let encoded = try ControlMessageCodec.encode(
            .ping(PingMessage(monotonicMs: 99, roundTripMs: 7))
        )
        guard case .ping(let ping) = try ControlMessageCodec.decode(encoded) else {
            return XCTFail("Expected ping")
        }
        XCTAssertEqual(ping.monotonicMs, 99)
        XCTAssertEqual(ping.roundTripMs, 7)
    }

    func testLegacyPingWithoutRTTStillDecodes() throws {
        let encoded = #"{"kind":"ping","monotonicMs":99}"#.data(using: .utf8)!
        guard case .ping(let ping) = try ControlMessageCodec.decode(encoded) else {
            return XCTFail("Expected ping")
        }
        XCTAssertNil(ping.roundTripMs)
    }

    func testRejectsUnexpectedAudioFrameSize() {
        XCTAssertThrowsError(try PacketCodec.decodeAudioFrame(Data(repeating: 0, count: 22)))
    }
}
