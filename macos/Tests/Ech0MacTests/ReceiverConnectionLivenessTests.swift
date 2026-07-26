import XCTest
@testable import Ech0Mac

final class ReceiverConnectionLivenessTests: XCTestCase {
    private final class SequenceRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Int] = []
        private var completed = false

        func append(_ value: Int) {
            lock.lock()
            values.append(value)
            lock.unlock()
        }

        func markCompleted() {
            lock.lock()
            completed = true
            lock.unlock()
        }

        func snapshot() -> ([Int], Bool) {
            lock.lock()
            defer { lock.unlock() }
            return (values, completed)
        }
    }

    func testHandshakeExpiresAfterTimeout() {
        XCTAssertNil(
            ReceiverConnectionLiveness.timeoutReason(
                didHandshake: false,
                acceptedAt: 10,
                lastPingAt: nil,
                now: 15,
                timeout: 5
            )
        )
        XCTAssertEqual(
            ReceiverConnectionLiveness.timeoutReason(
                didHandshake: false,
                acceptedAt: 10,
                lastPingAt: nil,
                now: 15.1,
                timeout: 5
            ),
            "handshakeTimeout"
        )
    }

    func testHeartbeatExpiresAfterTimeout() {
        XCTAssertNil(
            ReceiverConnectionLiveness.timeoutReason(
                didHandshake: true,
                acceptedAt: 10,
                lastPingAt: 20,
                now: 25,
                timeout: 5
            )
        )
        XCTAssertEqual(
            ReceiverConnectionLiveness.timeoutReason(
                didHandshake: true,
                acceptedAt: 10,
                lastPingAt: 20,
                now: 25.1,
                timeout: 5
            ),
            "heartbeatTimeout"
        )
    }

    func testMissingPingAfterHandshakeIsStale() {
        XCTAssertEqual(
            ReceiverConnectionLiveness.timeoutReason(
                didHandshake: true,
                acceptedAt: 10,
                lastPingAt: nil,
                now: 10,
                timeout: 5
            ),
            "heartbeatTimeout"
        )
    }

    func testStaleListenerGenerationIsRejected() {
        XCTAssertTrue(
            ReceiverCallbackGeneration.accepts(
                callbackGeneration: 7,
                currentGeneration: 7
            )
        )
        XCTAssertFalse(
            ReceiverCallbackGeneration.accepts(
                callbackGeneration: 6,
                currentGeneration: 7
            )
        )
    }

    func testTerminalControlsWaitForEachSendCompletion() {
        let recorder = SequenceRecorder()

        CompletionSequence.run(
            [1, 2, 3],
            send: { value, completion in
                recorder.append(value)
                completion(nil)
            },
            completion: { error in
                XCTAssertNil(error)
                recorder.markCompleted()
            }
        )

        let snapshot = recorder.snapshot()
        XCTAssertEqual(snapshot.0, [1, 2, 3])
        XCTAssertTrue(snapshot.1)
    }
}
