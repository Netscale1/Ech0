import AppKit
@preconcurrency import ApplicationServices
import Foundation
import os

enum CodexDictationAccessibilityState: Equatable, Sendable {
    case permissionRequired
    case unavailable
    case inactive
    case active

    var isActive: Bool { self == .active }

    var isAvailable: Bool {
        self == .inactive || self == .active
    }

    var label: String {
        switch self {
        case .permissionRequired:
            return "accessibility required"
        case .unavailable:
            return "unavailable"
        case .inactive:
            return "ready"
        case .active:
            return "recording"
        }
    }
}

enum CodexAccessibilityPollOutcome: String, Sendable {
    case permissionRequired
    case applicationUnavailable
    case cachedActive
    case cachedResult
    case fullScan
}

enum CodexAccessibilityFullScanReason: String, Sendable {
    case initial
    case interval
    case priority
    case cacheInvalidated
    case targetChanged
}

enum CodexAccessibilityScanScope: String, Sendable {
    case application
    case focusedAncestry
}

struct CodexAccessibilityPollMeasurement: Sendable {
    let startedAt: TimeInterval
    let duration: Duration
    let outcome: CodexAccessibilityPollOutcome
    let ranOnMainThread: Bool
}

struct CodexAccessibilityFullScanMeasurement: Sendable {
    let startedAt: TimeInterval
    let duration: Duration
    let reason: CodexAccessibilityFullScanReason
    let scope: CodexAccessibilityScanScope
    let nodesVisited: Int
    let matchesFound: Int
    let attributeReadFailures: Int
    let nodeLimitReached: Bool
    let overlapDetected: Bool
    let resolvedState: CodexDictationAccessibilityState
    let ranOnMainThread: Bool
}

struct CodexAccessibilityInstrumentation: Sendable {
    let recordPoll: @Sendable (CodexAccessibilityPollMeasurement) -> Void
    let recordFullScan: @Sendable (CodexAccessibilityFullScanMeasurement) -> Void
}

struct CodexAccessibilityScanActivity {
    private(set) var isScanning = false

    mutating func begin() -> Bool {
        let overlapDetected = isScanning
        isScanning = true
        return overlapDetected
    }

    mutating func end() {
        isScanning = false
    }
}

struct CodexAccessibilityTargetLifecycle {
    private(set) var pid: pid_t?

    mutating func observe(pid nextPID: pid_t?) -> Bool {
        let changed = pid != nextPID
        pid = nextPID
        return changed
    }

    mutating func reset() {
        pid = nil
    }
}

struct CodexAccessibilityScanScopePolicy {
    static func preferredScope(
        reason: CodexAccessibilityFullScanReason,
        windowCount: Int,
        cachedControlCount: Int
    ) -> CodexAccessibilityScanScope {
        guard cachedControlCount == 1, windowCount == 1 else { return .application }
        switch reason {
        case .interval, .priority:
            return .focusedAncestry
        case .initial, .cacheInvalidated, .targetChanged:
            return .application
        }
    }
}

struct CodexCapturePolicy {
    static func allowsManualFallback(
        accessibilityState: CodexDictationAccessibilityState,
        automaticCapturePaused: Bool
    ) -> Bool {
        !automaticCapturePaused && !accessibilityState.isAvailable
    }

    static func isCaptureDemandActive(
        accessibilityState: CodexDictationAccessibilityState,
        manualFallbackActive: Bool,
        independentInputConsumerActive: Bool,
        automaticCapturePaused: Bool
    ) -> Bool {
        guard !automaticCapturePaused else { return false }
        return accessibilityState.isActive
            || (manualFallbackActive && !accessibilityState.isAvailable)
            || independentInputConsumerActive
    }
}

struct CodexDictationAccessibilityStateResolver {
    private static let inactiveDescriptions: Set<String> = [
        "dictate",
        "detta",
        "start voice chat",
        "start new voice chat",
    ]
    private static let activeDescriptions: Set<String> = [
        "stop dictation",
        "stop voice chat",
        "transcribe and send",
        "arresta dettatura",
        "trascrivi e invia",
        "interrompi dettatura",
    ]

    static func resolve(buttonDescription: String) -> CodexDictationAccessibilityState? {
        let normalizedDescription = buttonDescription
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
        if activeDescriptions.contains(normalizedDescription) {
            return .active
        }
        if inactiveDescriptions.contains(normalizedDescription) {
            return .inactive
        }
        return nil
    }

    static func resolve(buttonDescriptions: [String]) -> CodexDictationAccessibilityState? {
        var foundInactiveControl = false
        for description in buttonDescriptions {
            switch resolve(buttonDescription: description) {
            case .active:
                return .active
            case .inactive:
                foundInactiveControl = true
            case .permissionRequired, .unavailable, nil:
                continue
            }
        }
        return foundInactiveControl ? .inactive : nil
    }
}

struct CodexAccessibilityFullScanSchedule {
    let fallbackInterval: TimeInterval
    let applicationFallbackInterval: TimeInterval
    private(set) var nextFullScanTime: TimeInterval = 0
    private(set) var nextApplicationFallbackTime: TimeInterval = 0
    private(set) var priorityScanRequested = false

    init(
        fallbackInterval: TimeInterval,
        applicationFallbackInterval: TimeInterval = 10
    ) {
        self.fallbackInterval = fallbackInterval
        self.applicationFallbackInterval = applicationFallbackInterval
    }

    mutating func requestPriorityScan() {
        priorityScanRequested = true
    }

    func shouldScan(
        at time: TimeInterval,
        cachedControlsBecameInvalid: Bool,
        hasPublishedState: Bool
    ) -> Bool {
        scanReason(
            at: time,
            cachedControlsBecameInvalid: cachedControlsBecameInvalid,
            hasPublishedState: hasPublishedState
        ) != nil
    }

    func scanReason(
        at time: TimeInterval,
        cachedControlsBecameInvalid: Bool,
        hasPublishedState: Bool
    ) -> CodexAccessibilityFullScanReason? {
        if priorityScanRequested { return .priority }
        if cachedControlsBecameInvalid { return .cacheInvalidated }
        if !hasPublishedState { return .initial }
        if time >= nextFullScanTime { return .interval }
        return nil
    }

    func allowsApplicationFallback(
        at time: TimeInterval,
        reason: CodexAccessibilityFullScanReason
    ) -> Bool {
        reason != .interval || time >= nextApplicationFallbackTime
    }

    mutating func didScan(
        at time: TimeInterval,
        scope: CodexAccessibilityScanScope = .application
    ) {
        priorityScanRequested = false
        nextFullScanTime = time + fallbackInterval
        if scope == .application {
            nextApplicationFallbackTime = time + applicationFallbackInterval
        }
    }

    mutating func reset() {
        nextFullScanTime = 0
        nextApplicationFallbackTime = 0
        priorityScanRequested = false
    }
}

private struct CodexAccessibilityFullScanResult {
    let matches: [(element: AXUIElement, description: String)]
    let scope: CodexAccessibilityScanScope
    let nodesVisited: Int
    let attributeReadFailures: Int
    let nodeLimitReached: Bool
}

private struct CodexAccessibilityNodeAttributes {
    let role: String?
    let children: [AXUIElement]
    let readFailed: Bool
}

final class CodexDictationAccessibilityMonitor: @unchecked Sendable {
    var onStateChanged: ((CodexDictationAccessibilityState) -> Void)?

    private static let signposter = OSSignposter(
        subsystem: "net.ech0.mac",
        category: "CodexAccessibility"
    )
    private let bundleIdentifier: String
    private let instrumentation: CodexAccessibilityInstrumentation?
    private let clock = ContinuousClock()
    private let queue = DispatchQueue(label: "net.ech0.codex-dictation-accessibility")
    private let queueKey = DispatchSpecificKey<Void>()
    private var timer: DispatchSourceTimer?
    private var targetLifecycle = CodexAccessibilityTargetLifecycle()
    private var cachedControls: [AXUIElement] = []
    private var currentState: CodexDictationAccessibilityState?
    private var fullScanSchedule = CodexAccessibilityFullScanSchedule(fallbackInterval: 5)
    private var scanActivity = CodexAccessibilityScanActivity()
    private var priorityRescanWorkItems: [DispatchWorkItem] = []

    init(
        bundleIdentifier: String = "com.openai.codex",
        instrumentation: CodexAccessibilityInstrumentation? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.instrumentation = instrumentation
        queue.setSpecific(key: queueKey, value: ())
    }

    func start(promptForPermission: Bool = true) {
        syncOnQueue {
            startOnQueue(promptForPermission: promptForPermission)
        }
    }

    private func startOnQueue(promptForPermission: Bool) {
        guard timer == nil else { return }

        if promptForPermission, !AXIsProcessTrusted() {
            requestPermission()
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(200), leeway: .milliseconds(30))
        timer.setEventHandler { [weak self] in self?.poll() }
        self.timer = timer
        timer.resume()
    }

    func requestPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    func requestPriorityRescan() {
        queue.async { [weak self] in
            guard let self else { return }
            self.priorityRescanWorkItems.forEach { $0.cancel() }
            self.priorityRescanWorkItems.removeAll()
            self.fullScanSchedule.requestPriorityScan()

            for delay in [0.25, 0.75] {
                let workItem = DispatchWorkItem { [weak self] in
                    guard let self, self.currentState != .active else { return }
                    self.fullScanSchedule.requestPriorityScan()
                }
                self.priorityRescanWorkItems.append(workItem)
                self.queue.asyncAfter(deadline: .now() + delay, execute: workItem)
            }
        }
    }

    func stop() {
        syncOnQueue {
            stopOnQueue()
        }
    }

    private func stopOnQueue() {
        timer?.cancel()
        timer = nil
        priorityRescanWorkItems.forEach { $0.cancel() }
        priorityRescanWorkItems.removeAll()
        targetLifecycle.reset()
        cachedControls = []
        currentState = nil
        fullScanSchedule.reset()
    }

    deinit {
        stop()
    }

    private func poll() {
        let pollStartedAt = instrumentation == nil
            ? nil
            : ProcessInfo.processInfo.systemUptime
        let pollStarted = instrumentation == nil ? nil : clock.now
        var pollOutcome = CodexAccessibilityPollOutcome.permissionRequired
        var fullScanMeasurement: CodexAccessibilityFullScanMeasurement?
        defer {
            if let instrumentation, let pollStartedAt, let pollStarted {
                instrumentation.recordPoll(CodexAccessibilityPollMeasurement(
                    startedAt: pollStartedAt,
                    duration: pollStarted.duration(to: clock.now),
                    outcome: pollOutcome,
                    ranOnMainThread: Thread.isMainThread
                ))
                if let fullScanMeasurement {
                    instrumentation.recordFullScan(fullScanMeasurement)
                }
            }
        }

        guard AXIsProcessTrusted() else {
            resetTarget()
            publish(.permissionRequired)
            return
        }

        guard let application = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        ).first else {
            pollOutcome = .applicationUnavailable
            resetTarget()
            publish(.unavailable)
            return
        }

        var targetChanged = false
        if targetLifecycle.observe(pid: application.processIdentifier) {
            targetChanged = true
            cachedControls = []
            fullScanSchedule.reset()
        }

        let now = ProcessInfo.processInfo.systemUptime
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        let previouslyHadCachedControls = !cachedControls.isEmpty
        var validMatches: [(element: AXUIElement, description: String)] = cachedControls.compactMap {
            guard let description = Self.stringAttribute(kAXDescriptionAttribute, from: $0) else {
                return nil
            }
            return ($0, description)
        }
        if validMatches.isEmpty,
           let focusedMatch = Self.focusedDictationControl(in: appElement) {
            validMatches.append(focusedMatch)
        }
        cachedControls = validMatches.map(\.element)

        let cachedDescriptions = validMatches.map(\.description)
        let cachedState = CodexDictationAccessibilityStateResolver.resolve(
            buttonDescriptions: cachedDescriptions
        )
        if cachedState == .active {
            pollOutcome = .cachedActive
            publish(.active)
            return
        }

        let cachedControlsBecameInvalid = previouslyHadCachedControls && validMatches.isEmpty
        let scanReason = targetChanged
            ? CodexAccessibilityFullScanReason.targetChanged
            : fullScanSchedule.scanReason(
                at: now,
                cachedControlsBecameInvalid: cachedControlsBecameInvalid,
                hasPublishedState: currentState != nil
            )
        guard let scanReason else {
            pollOutcome = .cachedResult
            publish(cachedState ?? .unavailable)
            return
        }

        pollOutcome = .fullScan
        let fullScanStartedAt = instrumentation == nil
            ? nil
            : ProcessInfo.processInfo.systemUptime
        let fullScanStarted = instrumentation == nil ? nil : clock.now
        let overlapDetected = scanActivity.begin()
        let signpostState = Self.signposter.beginInterval("AXScan")
        let scanResult = Self.scanDictationControls(
            in: appElement,
            reason: scanReason,
            cachedControlCount: validMatches.count,
            allowApplicationFallback: fullScanSchedule.allowsApplicationFallback(
                at: now,
                reason: scanReason
            )
        )
        let resolvedMatches: [(element: AXUIElement, description: String)]
        if scanResult.scope == .focusedAncestry {
            var mergedMatches = validMatches
            for match in scanResult.matches
            where !mergedMatches.contains(where: { CFEqual($0.element, match.element) }) {
                mergedMatches.append(match)
            }
            resolvedMatches = mergedMatches
        } else {
            resolvedMatches = scanResult.matches
        }
        cachedControls = resolvedMatches.map(\.element)
        fullScanSchedule.didScan(at: now, scope: scanResult.scope)
        let resolvedState = CodexDictationAccessibilityStateResolver.resolve(
            buttonDescriptions: resolvedMatches.map(\.description)
        ) ?? .unavailable
        Self.signposter.endInterval("AXScan", signpostState)
        scanActivity.end()

        if let fullScanStartedAt, let fullScanStarted {
            fullScanMeasurement = CodexAccessibilityFullScanMeasurement(
                startedAt: fullScanStartedAt,
                duration: fullScanStarted.duration(to: clock.now),
                reason: scanReason,
                scope: scanResult.scope,
                nodesVisited: scanResult.nodesVisited,
                matchesFound: scanResult.matches.count,
                attributeReadFailures: scanResult.attributeReadFailures,
                nodeLimitReached: scanResult.nodeLimitReached,
                overlapDetected: overlapDetected,
                resolvedState: resolvedState,
                ranOnMainThread: Thread.isMainThread
            )
        }
        publish(resolvedState)
    }

    private func resetTarget() {
        targetLifecycle.reset()
        cachedControls = []
        fullScanSchedule.reset()
    }

    private func publish(_ state: CodexDictationAccessibilityState) {
        guard state != currentState else { return }
        currentState = state
        DispatchQueue.main.async { [weak self] in
            self?.onStateChanged?(state)
        }
    }

    private static func scanDictationControls(
        in application: AXUIElement,
        reason: CodexAccessibilityFullScanReason,
        cachedControlCount: Int,
        allowApplicationFallback: Bool
    ) -> CodexAccessibilityFullScanResult {
        let windowCount = elementArrayAttribute(
            kAXWindowsAttribute,
            from: application
        )?.count ?? -1
        let preferredScope = CodexAccessibilityScanScopePolicy.preferredScope(
            reason: reason,
            windowCount: windowCount,
            cachedControlCount: cachedControlCount
        )
        guard preferredScope == .focusedAncestry else {
            return findDictationControls(in: application, scope: .application)
        }
        let focusedAttempt = findFocusedDictationControls(in: application)
            ?? CodexAccessibilityFullScanResult(
                matches: [],
                scope: .focusedAncestry,
                nodesVisited: 0,
                attributeReadFailures: 1,
                nodeLimitReached: false
            )
        guard focusedAttempt.matches.isEmpty else { return focusedAttempt }
        guard allowApplicationFallback else { return focusedAttempt }

        let applicationResult = findDictationControls(
            in: application,
            scope: .application
        )
        return CodexAccessibilityFullScanResult(
            matches: applicationResult.matches,
            scope: .application,
            nodesVisited: focusedAttempt.nodesVisited + applicationResult.nodesVisited,
            attributeReadFailures: focusedAttempt.attributeReadFailures
                + applicationResult.attributeReadFailures,
            nodeLimitReached: focusedAttempt.nodeLimitReached
                || applicationResult.nodeLimitReached
        )
    }

    private static func findFocusedDictationControls(
        in application: AXUIElement
    ) -> CodexAccessibilityFullScanResult? {
        guard var element = elementAttribute(
            kAXFocusedUIElementAttribute,
            from: application
        ) else {
            return nil
        }

        var nodesVisited = 0
        var attributeReadFailures = 0
        var nodeLimitReached = false
        for _ in 0..<8 {
            let result = findDictationControls(
                in: element,
                scope: .focusedAncestry,
                nodeLimit: 256
            )
            nodesVisited += result.nodesVisited
            attributeReadFailures += result.attributeReadFailures
            nodeLimitReached = nodeLimitReached || result.nodeLimitReached
            if !result.matches.isEmpty {
                return CodexAccessibilityFullScanResult(
                    matches: result.matches,
                    scope: .focusedAncestry,
                    nodesVisited: nodesVisited,
                    attributeReadFailures: attributeReadFailures,
                    nodeLimitReached: nodeLimitReached
                )
            }
            if result.nodeLimitReached { break }
            guard let parent = elementAttribute(kAXParentAttribute, from: element),
                  !CFEqual(parent, element) else {
                break
            }
            element = parent
        }

        return CodexAccessibilityFullScanResult(
            matches: [],
            scope: .focusedAncestry,
            nodesVisited: nodesVisited,
            attributeReadFailures: attributeReadFailures,
            nodeLimitReached: nodeLimitReached
        )
    }

    private static func findDictationControls(
        in root: AXUIElement,
        scope: CodexAccessibilityScanScope,
        nodeLimit: Int = 20_000
    ) -> CodexAccessibilityFullScanResult {
        var stack = [root]
        var visitedCount = 0
        var attributeReadFailures = 0
        var matches: [(element: AXUIElement, description: String)] = []

        while visitedCount < nodeLimit, let element = stack.popLast() {
            visitedCount += 1
            let attributes = roleAndChildren(of: element)
            if attributes.readFailed {
                attributeReadFailures += 1
            }

            if attributes.role == kAXButtonRole,
               let description = stringAttribute(kAXDescriptionAttribute, from: element),
               CodexDictationAccessibilityStateResolver.resolve(
                   buttonDescription: description
               ) != nil {
                matches.append((element, description))
            }

            stack.append(contentsOf: attributes.children.reversed())
        }

        return CodexAccessibilityFullScanResult(
            matches: matches,
            scope: scope,
            nodesVisited: visitedCount,
            attributeReadFailures: attributeReadFailures,
            nodeLimitReached: !stack.isEmpty
        )
    }

    private static func focusedDictationControl(
        in application: AXUIElement
    ) -> (element: AXUIElement, description: String)? {
        guard let element = elementAttribute(
            kAXFocusedUIElementAttribute,
            from: application
        ) else {
            return nil
        }
        guard
        stringAttribute(kAXRoleAttribute, from: element) == kAXButtonRole,
        let description = stringAttribute(kAXDescriptionAttribute, from: element),
        CodexDictationAccessibilityStateResolver.resolve(buttonDescription: description) != nil
        else {
            return nil
        }
        return (element, description)
    }

    private static func elementAttribute(
        _ attribute: String,
        from element: AXUIElement
    ) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success,
        let value,
        CFGetTypeID(value) == AXUIElementGetTypeID()
        else {
            return nil
        }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private static func elementArrayAttribute(
        _ attribute: String,
        from element: AXUIElement
    ) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success else {
            return nil
        }
        return value as? [AXUIElement]
    }

    private static func roleAndChildren(
        of element: AXUIElement
    ) -> CodexAccessibilityNodeAttributes {
        var values: CFArray?
        let attributes = [kAXRoleAttribute, kAXChildrenAttribute] as CFArray
        guard AXUIElementCopyMultipleAttributeValues(
            element,
            attributes,
            AXCopyMultipleAttributeOptions(rawValue: 0),
            &values
        ) == .success else {
            return CodexAccessibilityNodeAttributes(
                role: nil,
                children: [],
                readFailed: true
            )
        }
        let copiedValues = values as? [Any]
        return CodexAccessibilityNodeAttributes(
            role: copiedValues?[safe: 0] as? String,
            children: copiedValues?[safe: 1] as? [AXUIElement] ?? [],
            readFailed: false
        )
    }

    private static func stringAttribute(
        _ attribute: String,
        from element: AXUIElement
    ) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success else {
            return nil
        }
        return value as? String
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

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
