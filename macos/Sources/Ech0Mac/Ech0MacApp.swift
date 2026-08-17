import AppKit
import Combine
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

    var body: some Scene {
        Window("Ech0", id: "main") {
            MainWindowContent(
                model: appDelegate.model,
                registerRecreationAction: appDelegate.registerMainWindowRecreationAction
            )
        }
        .windowStyle(.automatic)
        .defaultSize(width: 840, height: 600)
    }
}

private struct MainWindowContent: View {
    @ObservedObject var model: ReceiverViewModel
    let registerRecreationAction: (@escaping () -> Void) -> Void

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ContentView(model: model)
            .onAppear {
                registerRecreationAction {
                    openWindow(id: "main")
                }
            }
    }
}

@MainActor
protocol MainWindowPresenting: AnyObject {
    func presentMainWindow()
}

extension NSWindow: MainWindowPresenting {
    func presentMainWindow() {
        makeKeyAndOrderFront(nil)
    }
}

@MainActor
final class MainWindowPresenter {
    private var recreateWindow: (() -> Void)?

    func registerRecreationAction(_ action: @escaping () -> Void) {
        recreateWindow = action
    }

    func show(existingWindow: (any MainWindowPresenting)?) {
        guard let existingWindow else {
            recreateWindow?()
            return
        }
        existingWindow.presentMainWindow()
    }
}

@MainActor
private final class Ech0AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let model = ReceiverViewModel()

    private var statusItem: NSStatusItem?
    private var modelObservation: AnyCancellable?
    private let mainWindowPresenter = MainWindowPresenter()
    private var shouldShowMainWindow = CommandLine.arguments.contains("--show-window")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installStatusItem()
        observeModel()

        DispatchQueue.main.async { [weak self] in
            self?.configureMainWindow()
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag {
            showMainWindow()
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu(menu)
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        refreshStatusItem()
    }

    private func observeModel() {
        modelObservation = model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                DispatchQueue.main.async {
                    self?.refreshStatusItem()
                }
            }
    }

    private func refreshStatusItem() {
        guard let button = statusItem?.button else { return }
        let image = Bundle.main.image(
            forResource: NSImage.Name(model.menuBarImageName)
        ) ?? NSImage(
            systemSymbolName: model.menuBarSymbolName,
            accessibilityDescription: "Ech0"
        )
        let renderedImage = image?.copy() as? NSImage
        renderedImage?.isTemplate = true
        renderedImage?.size = NSSize(width: 18, height: 18)
        button.image = renderedImage
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.toolTip = "Ech0 — \(model.connectionLabel)"
        button.setAccessibilityLabel("Ech0: \(model.connectionLabel)")
    }

    private func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(informationalItem(model.connectionLabel))
        menu.addItem(informationalItem("Windows capture: \(model.remoteCaptureState)"))
        menu.addItem(informationalItem("\(model.captureDeviceName) consumers: \(model.inputConsumers.count)"))
        menu.addItem(informationalItem(
            "System detection: \(model.automaticDetectionAvailable ? "ready" : "unavailable")"
        ))
        menu.addItem(.separator())
        menu.addItem(actionItem("Open Ech0", action: #selector(showMainWindow)))
        menu.addItem(actionItem(
            model.automaticCapturePaused ? "Resume automatic capture" : "Pause automatic capture",
            action: #selector(toggleAutomaticCapture)
        ))

        let manualItem = actionItem(
            model.manualCaptureActive ? "Stop manual capture" : "Start manually",
            action: #selector(toggleManualCapture)
        )
        manualItem.isEnabled = model.canUseManualFallback || model.manualCaptureActive
        menu.addItem(manualItem)

        let launchItem = actionItem("Launch at login", action: #selector(toggleLaunchAtLogin))
        launchItem.state = model.launchAtLoginEnabled ? .on : .off
        menu.addItem(launchItem)
        menu.addItem(.separator())
        menu.addItem(actionItem("Restart Ech0", action: #selector(restart)))
        menu.addItem(actionItem("Quit", action: #selector(quit)))
    }

    private func informationalItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func actionItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    func registerMainWindowRecreationAction(_ action: @escaping () -> Void) {
        mainWindowPresenter.registerRecreationAction(action)
        configureMainWindow()
    }

    private func configureMainWindow() {
        guard let window = mainWindow else { return }
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 840, height: 600))
        if shouldShowMainWindow {
            window.center()
            mainWindowPresenter.show(existingWindow: window)
        } else {
            window.orderOut(nil)
        }
    }

    private var mainWindow: NSWindow? {
        NSApp.windows.first {
            $0.title == "Ech0" && $0.styleMask.contains(.titled)
        }
    }

    @objc private func showMainWindow() {
        shouldShowMainWindow = true
        NSApp.activate(ignoringOtherApps: true)
        if mainWindow != nil {
            configureMainWindow()
        } else {
            mainWindowPresenter.show(existingWindow: nil)
        }
    }

    @objc private func toggleAutomaticCapture() {
        model.toggleAutomaticCapturePause()
    }

    @objc private func toggleManualCapture() {
        model.toggleManualCapture()
    }

    @objc private func toggleLaunchAtLogin() {
        model.setLaunchAtLogin(enabled: !model.launchAtLoginEnabled)
    }

    @objc private func restart() {
        let relaunchProcess = makeEch0RelaunchProcess(bundlePath: Bundle.main.bundlePath)
        do {
            try relaunchProcess.run()
            NSApp.terminate(nil)
        } catch {
            NSSound.beep()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
