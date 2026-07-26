import AppKit
import SwiftUI

func makeEch0RelaunchProcess(bundlePath: String) -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [
        "-c",
        "sleep 0.5; exec /usr/bin/open -n \"$1\"",
        "ech0-restart",
        bundlePath
    ]
    return process
}

@main
struct Ech0MacApp: App {
    @NSApplicationDelegateAdaptor(Ech0AppDelegate.self) private var appDelegate
    @StateObject private var model = ReceiverViewModel()

    var body: some Scene {
        Window("Ech0", id: "main") {
            ContentView(model: model)
        }
        .windowStyle(.automatic)
        .defaultSize(width: 840, height: 600)

        MenuBarExtra {
            MenuBarContent(model: model)
        } label: {
            Ech0MenuBarLabel(model: model)
        }
    }
}

private struct Ech0MenuBarLabel: View {
    @ObservedObject var model: ReceiverViewModel

    var body: some View {
        Image(nsImage: statusImage)
            .accessibilityLabel("Ech0: \(model.connectionLabel)")
    }

    private var statusImage: NSImage {
        let image = NSImage(named: NSImage.Name(model.menuBarImageName))
            ?? NSImage(
                systemSymbolName: model.menuBarSymbolName,
                accessibilityDescription: "Ech0"
            )!
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }
}

private final class Ech0AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        guard !CommandLine.arguments.contains("--show-window") else {
            DispatchQueue.main.async {
                NSApp.windows.first?.setContentSize(NSSize(width: 840, height: 600))
                NSApp.windows.first?.center()
            }
            return
        }
        DispatchQueue.main.async {
            NSApp.windows.forEach { $0.close() }
        }
    }
}

private struct MenuBarContent: View {
    @ObservedObject var model: ReceiverViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.connectionLabel)
        Text("Windows capture: \(model.remoteCaptureState)")
        Text("BlackHole consumers: \(model.inputConsumers.count)")
        Text("Codex detection: \(model.codexAccessibilityState.label)")
        Divider()
        Button("Open Ech0") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "main")
        }
        Button(model.automaticCapturePaused ? "Resume automatic capture" : "Pause automatic capture") {
            model.toggleAutomaticCapturePause()
        }
        Button(model.codexShortcutCaptureActive ? "Stop manual capture" : "Start manually") {
            model.toggleCodexShortcutCapture()
        }
        .disabled(model.automaticCapturePaused)
        if model.codexAccessibilityState == .permissionRequired {
            Button("Open Accessibility Settings") {
                model.openAccessibilitySettings()
            }
        }
        Toggle(
            "Launch at login",
            isOn: Binding(
                get: { model.launchAtLoginEnabled },
                set: { model.setLaunchAtLogin(enabled: $0) }
            )
        )
        Divider()
        Button("Restart Ech0") {
            let relaunchProcess = makeEch0RelaunchProcess(bundlePath: Bundle.main.bundlePath)
            do {
                try relaunchProcess.run()
                NSApp.terminate(nil)
            } catch {
                NSSound.beep()
            }
        }
        Button("Quit") {
            NSApp.terminate(nil)
        }
    }
}
