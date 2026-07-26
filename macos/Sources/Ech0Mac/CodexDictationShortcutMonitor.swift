import CoreGraphics
import Foundation

struct DoubleCommandDetector {
    let maximumInterval: TimeInterval

    private(set) var wasCommandDown = false
    private(set) var lastPressTime: TimeInterval?

    init(maximumInterval: TimeInterval = 0.45) {
        self.maximumInterval = maximumInterval
    }

    mutating func update(
        commandDown: Bool,
        otherModifierDown: Bool,
        timestamp: TimeInterval
    ) -> Bool {
        defer { wasCommandDown = commandDown }
        guard commandDown, !wasCommandDown, !otherModifierDown else { return false }

        guard let lastPressTime else {
            self.lastPressTime = timestamp
            return false
        }

        self.lastPressTime = timestamp
        return timestamp - lastPressTime <= maximumInterval
    }
}

final class CodexDictationShortcutMonitor: @unchecked Sendable {
    var onToggle: (() -> Void)?

    private let queue = DispatchQueue(label: "net.ech0.codex-dictation-shortcut")
    private let queueKey = DispatchSpecificKey<Void>()
    private var detector = DoubleCommandDetector()
    private var timer: DispatchSourceTimer?

    init() {
        queue.setSpecific(key: queueKey, value: ())
    }

    func start() {
        syncOnQueue {
            startOnQueue()
        }
    }

    private func startOnQueue() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(25), leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in self?.poll() }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        syncOnQueue {
            stopOnQueue()
        }
    }

    private func stopOnQueue() {
        timer?.cancel()
        timer = nil
    }

    deinit {
        stop()
    }

    private func poll() {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        let commandDown = flags.contains(.maskCommand)
        let otherModifierDown = flags.contains(.maskControl)
            || flags.contains(.maskAlternate)
            || flags.contains(.maskShift)
        let shouldToggle = detector.update(
            commandDown: commandDown,
            otherModifierDown: otherModifierDown,
            timestamp: ProcessInfo.processInfo.systemUptime
        )
        guard shouldToggle else { return }
        DispatchQueue.main.async { [weak self] in self?.onToggle?() }
    }

    var isRunning: Bool {
        syncOnQueue { timer != nil }
    }

    private func syncOnQueue<T>(_ body: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return body()
        }
        return queue.sync(execute: body)
    }
}
