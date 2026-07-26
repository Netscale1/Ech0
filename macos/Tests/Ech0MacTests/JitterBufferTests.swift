import XCTest
@testable import Ech0Mac

final class JitterBufferTests: XCTestCase {
    func testIdleClockOutputsSilenceWithoutGrowingUnderruns() {
        let buffer = JitterBuffer()

        let output = buffer.consumeMonoSamples(count: 512)

        XCTAssertEqual(output, Array(repeating: Int16(0), count: 512))
        XCTAssertEqual(buffer.snapshot().underruns, 0)
        XCTAssertEqual(buffer.snapshot().targetBufferMs, 60)
    }

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

    func testInPlaceConsumptionPreservesFrameOrderingAndZeroFillsRemainder() {
        let buffer = JitterBuffer()
        for sequence in 1...3 {
            let samples = Array(repeating: Int16(sequence), count: 960)
            buffer.push(
                AudioFrame(
                    sequence: UInt64(sequence),
                    captureTimestampMs: UInt64(sequence * 20),
                    flags: 0,
                    samples: samples
                )
            )
        }
        var output = Array(repeating: Int16.max, count: 3_000)

        output.withUnsafeMutableBufferPointer { samples in
            buffer.consumeMonoSamples(into: samples)
        }

        XCTAssertEqual(Array(output[0..<960]), Array(repeating: Int16(1), count: 960))
        XCTAssertEqual(Array(output[960..<1_920]), Array(repeating: Int16(2), count: 960))
        XCTAssertEqual(Array(output[1_920..<2_880]), Array(repeating: Int16(3), count: 960))
        XCTAssertEqual(Array(output[2_880..<3_000]), Array(repeating: Int16(0), count: 120))
        XCTAssertEqual(buffer.snapshot().underruns, 1)
    }

    func testQueuedSampleAccountingRemainsCorrectAfterOverrunDrops() {
        let buffer = JitterBuffer()
        let samples = Array(repeating: Int16(42), count: 960)

        for sequence in 1...10 {
            buffer.push(
                AudioFrame(
                    sequence: UInt64(sequence),
                    captureTimestampMs: UInt64(sequence * 20),
                    flags: 0,
                    samples: samples
                )
            )
        }

        let snapshot = buffer.snapshot()
        XCTAssertLessThanOrEqual(snapshot.bufferedMs, 120)
        XCTAssertEqual(snapshot.bufferedMs, snapshot.queuedFrames * 20)
        XCTAssertGreaterThan(snapshot.overruns, 0)
    }

    func testConcurrentPushAndConsumptionCompleteWithoutBlocking() {
        let buffer = JitterBuffer()
        let group = DispatchGroup()
        let producer = DispatchQueue(label: "jitter-buffer-producer")
        let consumer = DispatchQueue(label: "jitter-buffer-consumer")

        group.enter()
        producer.async {
            let samples = Array(repeating: Int16(7), count: 960)
            for sequence in 1...5_000 {
                buffer.push(
                    AudioFrame(
                        sequence: UInt64(sequence),
                        captureTimestampMs: UInt64(sequence * 20),
                        flags: 0,
                        samples: samples
                    )
                )
            }
            group.leave()
        }

        group.enter()
        consumer.async {
            var output = Array(repeating: Int16.max, count: 512)
            for _ in 0..<5_000 {
                output.withUnsafeMutableBufferPointer { samples in
                    buffer.consumeMonoSamples(into: samples)
                }
            }
            group.leave()
        }

        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertLessThanOrEqual(buffer.snapshot().bufferedMs, 120)
    }

    func testInitialPreRollDoesNotIncreaseTargetOrUnderruns() {
        let buffer = JitterBuffer()
        let samples = Array(repeating: Int16(300), count: 960)
        buffer.push(AudioFrame(sequence: 1, captureTimestampMs: 10, flags: 0, samples: samples))

        for _ in 0..<5 {
            XCTAssertEqual(
                buffer.consumeMonoSamples(count: 512),
                Array(repeating: Int16(0), count: 512)
            )
        }

        XCTAssertEqual(buffer.snapshot().targetBufferMs, 60)
        XCTAssertEqual(buffer.snapshot().underruns, 0)
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
