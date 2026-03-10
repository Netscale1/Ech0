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
