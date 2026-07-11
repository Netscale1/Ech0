import Foundation

struct JitterBufferSnapshot {
    let bufferedMs: Int
    let targetBufferMs: Int
    let underruns: Int
    let overruns: Int
    let staleDrops: Int
    let queuedFrames: Int
}

final class JitterBuffer {
    private let lock = NSLock()
    private var queuedFrames: [AudioFrame] = []
    private var currentFrame: AudioFrame?
    private var currentSampleIndex = 0
    private var isPrimedForPlayback = false
    private var hasReceivedFrameSinceReset = false
    private var lastSequence: UInt64?
    private var stableReads = 0

    private let minTargetMs = 40
    private let maxTargetMs = 120

    private(set) var targetBufferMs = 60
    private(set) var underruns = 0
    private(set) var overruns = 0
    private(set) var staleDrops = 0

    func reset() {
        lock.withLock {
            queuedFrames.removeAll()
            currentFrame = nil
            currentSampleIndex = 0
            isPrimedForPlayback = false
            hasReceivedFrameSinceReset = false
            lastSequence = nil
            stableReads = 0
            targetBufferMs = 60
            underruns = 0
            overruns = 0
            staleDrops = 0
        }
    }

    func push(_ frame: AudioFrame) {
        lock.withLock {
            if let lastSequence, frame.sequence <= lastSequence {
                staleDrops += 1
                return
            }

            lastSequence = frame.sequence
            hasReceivedFrameSinceReset = true
            queuedFrames.append(frame)

            while bufferedMsUnlocked() > maxTargetMs, !queuedFrames.isEmpty {
                queuedFrames.removeFirst()
                overruns += 1
                targetBufferMs = max(minTargetMs, targetBufferMs - 10)
            }
        }
    }

    func consumeMonoSamples(count: Int) -> [Int16] {
        lock.withLock {
            var output = Array(repeating: Int16(0), count: count)
            guard hasReceivedFrameSinceReset else { return output }
            var filled = 0

            while filled < count {
                if currentFrame == nil || currentSampleIndex >= (currentFrame?.samples.count ?? 0) {
                    currentFrame = nil
                    currentSampleIndex = 0

                    guard isPrimedForPlayback || bufferedMsUnlocked() >= targetBufferMs else {
                        break
                    }

                    guard !queuedFrames.isEmpty else {
                        break
                    }
                    currentFrame = queuedFrames.removeFirst()
                    isPrimedForPlayback = true
                }

                guard let frame = currentFrame else { break }
                let available = frame.samples.count - currentSampleIndex
                let take = min(available, count - filled)
                output.replaceSubrange(
                    filled..<(filled + take),
                    with: frame.samples[currentSampleIndex..<(currentSampleIndex + take)]
                )
                currentSampleIndex += take
                filled += take
            }

            if filled < count {
                underruns += 1
                targetBufferMs = min(maxTargetMs, targetBufferMs + 20)
                stableReads = 0
                if currentFrame == nil && queuedFrames.isEmpty {
                    isPrimedForPlayback = false
                }
            } else {
                stableReads += 1
                if stableReads >= 50, targetBufferMs > minTargetMs, bufferedMsUnlocked() > targetBufferMs {
                    targetBufferMs = max(minTargetMs, targetBufferMs - 10)
                    stableReads = 0
                }
            }

            return output
        }
    }

    func snapshot() -> JitterBufferSnapshot {
        lock.withLock {
            JitterBufferSnapshot(
                bufferedMs: bufferedMsUnlocked(),
                targetBufferMs: targetBufferMs,
                underruns: underruns,
                overruns: overruns,
                staleDrops: staleDrops,
                queuedFrames: queuedFrames.count + (currentFrame == nil ? 0 : 1)
            )
        }
    }

    private func bufferedMsUnlocked() -> Int {
        let queuedSamples = queuedFrames.reduce(0) { $0 + $1.samples.count }
        let currentSamples = currentFrame.map { max(0, $0.samples.count - currentSampleIndex) } ?? 0
        return (queuedSamples + currentSamples) * 1_000 / 48_000
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
