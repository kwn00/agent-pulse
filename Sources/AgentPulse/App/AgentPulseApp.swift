import AppKit
import SwiftUI

/// Plain AppKit entry point. A SwiftUI `App` would need at least one scene (e.g. `Settings`), and
/// that scene's ⌘, key equivalent could pop an empty window; the status bar panel is our only UI.
@main
enum AgentPulseMain {
    @MainActor private static let delegate = AppDelegate()

    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        // Works even when launched as a bare executable (swift run) without LSUIElement.
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: UsageStore?
    private var statusBar: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {

        let arguments = CommandLine.arguments
        if arguments.contains("--probe") {
            Task { await ProbeCommand.run() }
            return
        }
        if let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count {
            var scrolledBy: CGFloat?
            if let scrollIndex = arguments.firstIndex(of: "--scrolled"), scrollIndex + 1 < arguments.count {
                scrolledBy = Double(arguments[scrollIndex + 1]).map { CGFloat($0) }
            }
            Task {
                await SnapshotCommand.run(
                    outputPath: arguments[index + 1],
                    settingsPane: arguments.contains("--settings"),
                    scrolledBy: scrolledBy,
                    tilesOnly: arguments.contains("--tiles")
                )
            }
            return
        }

        // One menu bar icon is plenty: a second launch hands off to the running instance and quits.
        guard SingleInstance.acquire() else {
            NSApp.terminate(nil)
            return
        }

        let store = UsageStore(providers: ProviderRegistry.makeDefault(), cache: ProviderRegistry.isDemo ? nil : .default)
        self.store = store
        statusBar = StatusBarController(store: store)
        store.start()

        SingleInstance.onShowRequest { [weak self] in
            self?.statusBar?.show()
        }

        if arguments.contains("--open") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let statusBar = self?.statusBar else { return }
                statusBar.show(startInSettings: arguments.contains("--settings"))
                print("panel window: \(statusBar.panelWindowNumber)")
                fflush(stdout)
            }
        }
        // Dev aid: flip the menu bar mode on a timer so the settings-pane resize can be filmed.
        if arguments.contains("--debug-toggle-pin") {
            Timer.scheduledTimer(withTimeInterval: 1.6, repeats: true) { _ in
                Task { @MainActor in
                    let settings = AppSettings.shared
                    withAnimation(.spring(duration: 0.35, bounce: 0.15)) {
                        settings.menuBarStyle = settings.menuBarStyle == .pinned ? .highestUsage : .pinned
                    }
                }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
