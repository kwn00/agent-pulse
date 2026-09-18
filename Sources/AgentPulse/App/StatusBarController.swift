import AppKit
import Combine
import SwiftUI

@MainActor
final class StatusBarController: NSObject {
    private let store: UsageStore
    private let settings: AppSettings
    private let statusItem: NSStatusItem
    private let panel: PulsePanel
    private let hostingView: NSHostingView<PulsePanelView>
    private let layout = PanelLayout()
    private var contentSize = CGSize(width: Theme.panelWidth, height: 420)
    private var outsideClickMonitor: Any?
    private var cancellables = Set<AnyCancellable>()
    private var isPresenting = false
    private var isHiding = false
    /// App that had focus before we activated, so dismissing the panel hands focus straight back.
    private var previousApp: NSRunningApplication?

    init(store: UsageStore, settings: AppSettings = .shared) {
        self.store = store
        self.settings = settings
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        panel = PulsePanel(contentRect: NSRect(origin: .zero, size: contentSize))

        // Placeholder root; replaced right after super.init once `self` is available.
        hostingView = NSHostingView(rootView: PulsePanelView(store: store, settings: settings, layout: layout, onSizeChange: { _ in }, onQuit: {}))
        super.init()

        hostingView.rootView = PulsePanelView(
            store: store,
            settings: settings,
            layout: layout,
            onSizeChange: { [weak self] size in self?.contentSizeChanged(size) },
            onQuit: { NSApp.terminate(nil) }
        )
        hostingView.sizingOptions = []
        hostingView.autoresizingMask = [.width, .height]
        hostingView.frame = NSRect(origin: .zero, size: contentSize)
        panel.contentView = hostingView
        panel.onDismissRequest = { [weak self] in self?.hide() }

        configureButton()
        bind()
    }

    // MARK: - Status item

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.image = MenuBarIcon.image()
        button.image?.isTemplate = true
        button.imagePosition = .imageLeading
        button.target = self
        button.action = #selector(handleClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = "Agent Pulse"
        updateTitle()
    }

    private func bind() {
        store.$states
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateTitle() }
            .store(in: &cancellables)

        settings.$menuBarStyle
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateTitle() }
            .store(in: &cancellables)

        settings.$enabledProviders
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateTitle() }
            .store(in: &cancellables)

        settings.$pinnedProvider
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateTitle() }
            .store(in: &cancellables)
    }

    private func updateTitle() {
        guard let button = statusItem.button else { return }
        switch settings.menuBarStyle {
        case .iconOnly:
            button.attributedTitle = NSAttributedString(string: "")
        case .highestUsage, .pinned:
            if let fraction = store.menuBarFraction {
                let percent = Int((fraction * 100).rounded())
                let color: NSColor = fraction >= 0.9 ? NSColor(Theme.Palette.danger)
                    : fraction >= 0.75 ? NSColor(Theme.Palette.warning)
                    : .labelColor
                button.attributedTitle = NSAttributedString(
                    string: " \(percent)%",
                    attributes: [
                        .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
                        .foregroundColor: color,
                        .baselineOffset: 0.5,
                    ]
                )
            } else {
                button.attributedTitle = NSAttributedString(string: "")
            }
        }
    }

    @objc private func handleClick(_ sender: Any?) {
        guard let event = NSApp.currentEvent else {
            toggle()
            return
        }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showContextMenu()
        } else {
            toggle()
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        let refresh = NSMenuItem(title: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = settings.launchAtLogin ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Agent Pulse", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func refreshNow() { store.refreshAll() }

    @objc private func toggleLaunchAtLogin() { settings.launchAtLogin.toggle() }

    // MARK: - Panel presentation

    var panelWindowNumber: Int { panel.windowNumber }

    func toggle() {
        (panel.isVisible && !isHiding) ? hide() : show()
    }

    func show(startInSettings: Bool = false) {
        guard !isPresenting, !panel.isVisible || isHiding else { return }
        isPresenting = true
        isHiding = false
        store.markPresented(startInSettings: startInSettings)
        updateLayoutLimits()
        hostingView.layoutSubtreeIfNeeded()

        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp = frontmost
        }

        let target = targetFrame(for: contentSize)
        var start = target
        start.origin.y += 10
        panel.setFrame(start, display: false)
        panel.alphaValue = 0
        statusItem.button?.highlight(true)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(target, display: true)
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.isPresenting = false
                // Data may have landed mid-animation; catch the frame up with the content.
                let frame = self.targetFrame(for: self.contentSize)
                if self.panel.frame.size != frame.size { self.panel.setFrame(frame, display: true) }
            }
        }

        installOutsideClickMonitor()
    }

    func hide() {
        guard panel.isVisible, !isHiding else { return }
        isHiding = true
        removeOutsideClickMonitor()
        statusItem.button?.highlight(false)

        // If the user didn't click into another app, give focus back to where it came from.
        if NSApp.isActive, let previousApp, !previousApp.isTerminated {
            previousApp.activate()
        }
        previousApp = nil

        var end = panel.frame
        end.origin.y += 6
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            panel.animator().setFrame(end, display: true)
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.isHiding else { return }
                self.isHiding = false
                self.panel.orderOut(nil)
            }
        }
    }

    /// SwiftUI reports its animated size every frame, so the window simply tracks it. Running a
    /// second AppKit animation here would drift out of phase and make the content wobble.
    private func contentSizeChanged(_ size: CGSize) {
        guard size.width > 0, size.height > 0, size != contentSize else { return }
        contentSize = size
        guard !isPresenting else { return }
        panel.setFrame(targetFrame(for: size), display: panel.isVisible)
    }

    /// Header + footer + margins take ~170pt; the card list gets the rest of the screen, within reason.
    private func updateLayoutLimits() {
        let screen = statusItem.button?.window?.screen ?? NSScreen.main
        let available = (screen?.visibleFrame.height ?? 800) - 170
        layout.maxListHeight = min(max(available, 240), 900)
    }

    /// Centers the panel under the status item and keeps it inside the screen.
    private func targetFrame(for size: CGSize) -> NSRect {
        guard let button = statusItem.button, let buttonWindow = button.window else {
            return NSRect(origin: .zero, size: size)
        }
        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = buttonWindow.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        var x = buttonFrame.midX - size.width / 2
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        let y = buttonFrame.minY - 6 - size.height
        return NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
    }

    private func installOutsideClickMonitor() {
        removeOutsideClickMonitor()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.hide() }
        }
    }

    private func removeOutsideClickMonitor() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
    }
}

enum MenuBarIcon {
    /// 18×18 template glyph: heartbeat line inside a soft rounded frame.
    static func image() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let path = NSBezierPath()
            path.lineWidth = 1.7
            path.lineCapStyle = .round
            path.lineJoinStyle = .round

            let inset = rect.insetBy(dx: 1.2, dy: 4.5)
            let w = inset.width
            let midY = inset.midY
            path.move(to: NSPoint(x: inset.minX, y: midY))
            path.line(to: NSPoint(x: inset.minX + w * 0.24, y: midY))
            path.line(to: NSPoint(x: inset.minX + w * 0.36, y: inset.minY + inset.height * 0.22))
            path.line(to: NSPoint(x: inset.minX + w * 0.52, y: inset.maxY))
            path.line(to: NSPoint(x: inset.minX + w * 0.66, y: inset.minY))
            path.line(to: NSPoint(x: inset.minX + w * 0.76, y: midY))
            path.line(to: NSPoint(x: inset.maxX, y: midY))

            NSColor.black.setStroke()
            path.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }
}
