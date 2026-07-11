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

final class CodexDictationAccessibilityMonitor {
    var onStateChanged: ((CodexDictationAccessibilityState) -> Void)?

    private let bundleIdentifier: String
    private let queue = DispatchQueue(label: "net.ech0.codex-dictation-accessibility")
    private var timer: DispatchSourceTimer?
    private var targetPID: pid_t?
    private var cachedControls: [AXUIElement] = []
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
        cachedControls = []
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
            cachedControls = []
            nextFullScanTime = 0
        }

        let now = ProcessInfo.processInfo.systemUptime
        if now < nextFullScanTime {
            let descriptions = cachedControls.compactMap {
                Self.stringAttribute(kAXDescriptionAttribute, from: $0)
            }
            if let state = CodexDictationAccessibilityStateResolver.resolve(
                buttonDescriptions: descriptions
            ) {
                publish(state)
                return
            }
            if cachedControls.isEmpty {
                return
            }
        }

        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        let matches = Self.findDictationControls(in: appElement)
        cachedControls = matches.map(\.element)
        nextFullScanTime = now + 0.5
        if let state = CodexDictationAccessibilityStateResolver.resolve(
            buttonDescriptions: matches.map(\.description)
        ) {
            publish(state)
        } else {
            publish(.unavailable)
        }
    }

    private func resetTarget() {
        targetPID = nil
        cachedControls = []
        nextFullScanTime = 0
    }

    private func publish(_ state: CodexDictationAccessibilityState) {
        guard state != currentState else { return }
        currentState = state
        DispatchQueue.main.async { [weak self] in
            self?.onStateChanged?(state)
        }
    }

    private static func findDictationControls(
        in root: AXUIElement
    ) -> [(element: AXUIElement, description: String)] {
        var stack = [root]
        var visitedCount = 0
        var matches: [(element: AXUIElement, description: String)] = []

        while let element = stack.popLast(), visitedCount < 20_000 {
            visitedCount += 1

            if stringAttribute(kAXRoleAttribute, from: element) == kAXButtonRole,
               let description = stringAttribute(kAXDescriptionAttribute, from: element),
               CodexDictationAccessibilityStateResolver.resolve(
                   buttonDescription: description
               ) != nil {
                matches.append((element, description))
            }

            stack.append(contentsOf: children(of: element).reversed())
        }

        return matches
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
