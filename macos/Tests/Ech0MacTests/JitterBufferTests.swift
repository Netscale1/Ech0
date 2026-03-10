import XCTest
@testable import Ech0Mac

final class JitterBufferTests: XCTestCase {
    func testConsumesBufferedAudioAfterTargetReached() {
        let buffer = JitterBuffer()
        let samples = Array(repeating: Int16(300), count: 960)

        buffer.push(AudioFrame(sequence: 1, captureTimestampMs: 10, flags: 0, samples: samples))
        buffer.push(AudioFrame(sequence: 2, captureTimestampMs: 30, flags: 0, samples: samples))
        buffer.push(AudioFrame(sequence: 3, captureTimestampMs: 50, flags: 0, samples: samples))

        let output = buffer.consumeMonoSamples(count: 960)

        XCTAssertEqual(output.first, 300)
        XCTAssertEqual(buffer.snapshot().bufferedMs, 40)
    }

    func testDropsStaleFrames() {
        let buffer = JitterBuffer()
        let samples = Array(repeating: Int16(50), count: 960)

        buffer.push(AudioFrame(sequence: 3, captureTimestampMs: 30, flags: 0, samples: samples))
        buffer.push(AudioFrame(sequence: 2, captureTimestampMs: 20, flags: 0, samples: samples))

        XCTAssertEqual(buffer.snapshot().staleDrops, 1)
    }

    func testContinuesAcrossFrameBoundariesAfterInitialPriming() {
        let buffer = JitterBuffer()
        let samples = Array(repeating: Int16(120), count: 960)

        for sequence in 1...4 {
            buffer.push(AudioFrame(sequence: UInt64(sequence), captureTimestampMs: UInt64(sequence * 20), flags: 0, samples: samples))
        }

        let firstRead = buffer.consumeMonoSamples(count: 512)
        let secondRead = buffer.consumeMonoSamples(count: 512)
        let thirdRead = buffer.consumeMonoSamples(count: 512)

        XCTAssertEqual(firstRead, Array(repeating: Int16(120), count: 512))
        XCTAssertEqual(secondRead, Array(repeating: Int16(120), count: 512))
        XCTAssertEqual(thirdRead, Array(repeating: Int16(120), count: 512))
        XCTAssertEqual(buffer.snapshot().underruns, 0)
    }
}
