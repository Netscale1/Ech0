import XCTest
@testable import Ech0Mac

final class AudioFrameMetricsAccumulatorTests: XCTestCase {
    func testAggregatesFramesWithoutPublishingPerFrame() {
        let accumulator = AudioFrameMetricsAccumulator()

        XCTAssertNil(accumulator.record(sequence: 1, level: 0.25, at: 10))
        XCTAssertNil(accumulator.record(sequence: 2, level: 0.5, at: 10.02))

        let snapshot = accumulator.snapshotAndDecay()
        XCTAssertEqual(snapshot.framesReceived, 2)
        XCTAssertEqual(snapshot.lastSequence, 2)
        XCTAssertEqual(snapshot.inputLevel, 0.5)
        XCTAssertEqual(snapshot.peakLevel, 0.5)
    }

    func testReportsFirstFrameLatencyOncePerDemand() {
        let accumulator = AudioFrameMetricsAccumulator()
        accumulator.beginDemand(at: 20)

        XCTAssertEqual(accumulator.record(sequence: 1, level: 0, at: 20.125), 125)
        XCTAssertNil(accumulator.record(sequence: 2, level: 0, at: 20.145))

        accumulator.endDemand()
        accumulator.beginDemand(at: 30)
        XCTAssertEqual(accumulator.record(sequence: 3, level: 0, at: 30.05), 50)
    }
}
