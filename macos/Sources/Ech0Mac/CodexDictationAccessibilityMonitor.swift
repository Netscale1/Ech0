import AppKit
import ApplicationServices
import Foundation

enum CodexDictationAccessibilityState: Equatable {
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

struct CodexDictationAccessibilityStateResolver {
    static func resolve(buttonDescription: String) -> CodexDictationAccessibilityState? {
        switch buttonDescription {
        case "Stop dictation", "Transcribe and send":
            return .active
        case "Dictate":
            return .inactive
        default:
            return nil
        }
    }
}

final class CodexDictationAccessibilityMonitor {
    var onStateChanged: ((CodexDictationAccessibilityState) -> Void)?

    private let bundleIdentifier: String
    private let queue = DispatchQueue(label: "net.ech0.codex-dictation-accessibility")
    private var timer: DispatchSourceTimer?
    private var targetPID: pid_t?
    private var cachedControl: AXUIElement?
    private var currentState: CodexDictationAccessibilityState?
    private var nextFullScanTime: TimeInterval = 0

    init(bundleIdentifier: String = "com.openai.codex") {
        self.bundleIdentifier = bundleIdentifier
    }

    func start(promptForPermission: Bool = true) {
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

    func stop() {
        timer?.cancel()
        timer = nil
        targetPID = nil
        cachedControl = nil
    }

    deinit {
        stop()
    }

    private func poll() {
        guard AXIsProcessTrusted() else {
            resetTarget()
            publish(.permissionRequired)
            return
        }

        guard let application = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        ).first else {
            resetTarget()
            publish(.unavailable)
            return
        }

        if targetPID != application.processIdentifier {
            targetPID = application.processIdentifier
            cachedControl = nil
            nextFullScanTime = 0
        }

        if let cachedControl,
           let description = Self.stringAttribute(kAXDescriptionAttribute, from: cachedControl),
           let state = CodexDictationAccessibilityStateResolver.resolve(
               buttonDescription: description
           ) {
            publish(state)
            return
        }

        cachedControl = nil
        let now = ProcessInfo.processInfo.systemUptime
        guard now >= nextFullScanTime else { return }

        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        if let match = Self.findDictationControl(in: appElement) {
            cachedControl = match.element
            publish(match.state)
        } else {
            nextFullScanTime = now + 1
            publish(.unavailable)
        }
    }

    private func resetTarget() {
        targetPID = nil
        cachedControl = nil
        nextFullScanTime = 0
    }

    private func publish(_ state: CodexDictationAccessibilityState) {
        guard state != currentState else { return }
        currentState = state
        DispatchQueue.main.async { [weak self] in
            self?.onStateChanged?(state)
        }
    }

    private static func findDictationControl(
        in root: AXUIElement
    ) -> (element: AXUIElement, state: CodexDictationAccessibilityState)? {
        var stack = [root]
        var visitedCount = 0

        while let element = stack.popLast(), visitedCount < 20_000 {
            visitedCount += 1

            if stringAttribute(kAXRoleAttribute, from: element) == kAXButtonRole,
               let description = stringAttribute(kAXDescriptionAttribute, from: element),
               let state = CodexDictationAccessibilityStateResolver.resolve(
                   buttonDescription: description
               ) {
                return (element, state)
            }

            stack.append(contentsOf: children(of: element).reversed())
        }

        return nil
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &value
        ) == .success else {
            return []
        }
        return value as? [AXUIElement] ?? []
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
}
