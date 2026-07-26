import Foundation

struct AudioFrameMetricsSnapshot: Equatable {
    let framesReceived: Int
    let lastSequence: UInt64?
    let inputLevel: Double
    let peakLevel: Double
}

final class AudioFrameMetricsAccumulator {
    private let lock = NSLock()
    private var framesReceived = 0
    private var lastSequence: UInt64?
    private var inputLevel = 0.0
    private var peakLevel = 0.0
    private var demandStartedAt: TimeInterval?
    private var loggedFirstFrameForDemand = false

    func beginDemand(at timestamp: TimeInterval) {
        withLock {
            demandStartedAt = timestamp
            loggedFirstFrameForDemand = false
        }
    }

    func endDemand() {
        withLock {
            demandStartedAt = nil
            loggedFirstFrameForDemand = false
        }
    }

    func record(sequence: UInt64, level: Double, at timestamp: TimeInterval) -> Int? {
        withLock {
            framesReceived += 1
            lastSequence = sequence
            inputLevel = max(level, inputLevel * 0.7)
            peakLevel = max(level, peakLevel * 0.96)

            guard !loggedFirstFrameForDemand, let demandStartedAt else { return nil }
            loggedFirstFrameForDemand = true
            return max(0, Int((timestamp - demandStartedAt) * 1_000))
        }
    }

    func snapshotAndDecay() -> AudioFrameMetricsSnapshot {
        withLock {
            let snapshot = AudioFrameMetricsSnapshot(
                framesReceived: framesReceived,
                lastSequence: lastSequence,
                inputLevel: inputLevel,
                peakLevel: peakLevel
            )
            inputLevel *= 0.55
            peakLevel *= 0.92
            return snapshot
        }
    }

    func reset() {
        withLock {
            framesReceived = 0
            lastSequence = nil
            inputLevel = 0
            peakLevel = 0
            demandStartedAt = nil
            loggedFirstFrameForDemand = false
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
