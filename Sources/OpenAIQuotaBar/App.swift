import AppKit
import SwiftUI

@main
struct LLMUsageApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

final class GlassPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: Store!
    private var statusItem: NSStatusItem?
    private var panel: GlassPanel!
    private var clickMonitor: Any?
    private var localMonitor: Any?
    private var refreshTimer: Timer?
    private let arguments = ProcessInfo.processInfo.arguments

    func applicationDidFinishLaunching(_ notification: Notification) {
        let preview = arguments.contains("--preview")
        store = Store(ephemeral: preview)
        store.pool.grantProvider = { [weak store] id, selection in
            guard let store else { throw UsageError.message("Open LLM Usage to switch accounts.") }
            return try await store.routingGrant(id, selectionID: selection)
        }
        if preview {
            store.showingDemo = arguments.contains("--demo")
            if arguments.contains("--editor") || arguments.contains("--signin") { store.startAdding() }
            if arguments.contains("--signin-error") { store.signInState = .failed("This sign-in expired. Try again for a fresh code.") }
            if ["--error", "--unfetched", "--unlimited", "--exhausted", "--long-name"].contains(where: arguments.contains) {
                var sample = Account.samples[0]
                if arguments.contains("--error") { sample.error = "Please sign in again to refresh this account." }
                if arguments.contains("--unfetched") { sample.lastUpdated = nil; sample.codexUsage = nil; sample.tokenActivity = nil }
                if arguments.contains("--unlimited") { sample.monthlyLimit = nil; sample.codexUsage?.rateLimits.primary = nil; sample.codexUsage?.rateLimits.secondary = nil }
                if arguments.contains("--exhausted") { sample.usedTokens = 2_100_000; sample.codexUsage?.rateLimits.primary?.usedPercent = 100 }
                if arguments.contains("--long-name") { sample.name = "My incredibly long organization workspace name" }
                try? store.saveAccount(sample, key: "")
                store.openAccount(sample)
            }
            if arguments.contains("--five-accounts") {
                for sample in Account.samples { try? store.saveAccount(sample, key: "") }
            }
            if arguments.contains("--detail"), let account = store.selectedAccount { store.openAccount(account) }
            if arguments.contains("--settings") { store.showingSettings = true }
            if arguments.contains("--devices") { store.pool.showingDevices = true }
            if arguments.contains("--account-settings") {
                let sample = Account.samples[0]
                try? store.saveAccount(sample, key: "")
                store.startEditing(sample)
            }
        }
        // An activating panel gives editable account names normal keyboard focus,
        // including on macOS 27 where nonactivating panels can retain stale focus.
        panel = GlassPanel(contentRect: NSRect(x: 0, y: 0, width: 396, height: 660), styleMask: [.borderless], backing: .buffered, defer: false)
        panel.title = preview ? "LLM Usage · Design Preview" : "LLM Usage"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let hosting = NSHostingView(rootView: ContentView(close: { [weak self] in self?.hidePanel() }).environmentObject(store).environmentObject(store.pool))
        hosting.frame = NSRect(x: 0, y: 0, width: 396, height: 660)
        hosting.autoresizingMask = [.width, .height]
        // Clip the entire native effect, including its rim and backing layers.
        // Clipping only SwiftUI leaves square glass-layer edges in dark mode.
        let roundedContainer = NSView(frame: hosting.frame)
        roundedContainer.wantsLayer = true
        roundedContainer.layer?.backgroundColor = NSColor.clear.cgColor
        roundedContainer.layer?.cornerRadius = 28
        roundedContainer.layer?.cornerCurve = .continuous
        roundedContainer.layer?.masksToBounds = true
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: hosting.frame)
            glass.autoresizingMask = [.width, .height]
            glass.style = .regular
            glass.cornerRadius = 28
            glass.contentView = hosting
            roundedContainer.addSubview(glass)
        } else {
            let material = NSVisualEffectView(frame: hosting.frame)
            material.autoresizingMask = [.width, .height]
            material.material = .popover
            material.blendingMode = .behindWindow
            material.state = .active
            material.wantsLayer = true
            material.layer?.cornerRadius = 28
            material.layer?.masksToBounds = true
            material.addSubview(hosting)
            roundedContainer.addSubview(material)
        }
        panel.contentView = roundedContainer
        store.onThemeChanged = { [weak self] theme in
            self?.panel.appearance = theme.appearance
            self?.panel.invalidateShadow()
        }
        panel.appearance = store.theme.appearance
        if preview, arguments.contains("--dark") { try? store.setTheme(.dark) }
        if preview, arguments.contains("--light") { try? store.setTheme(.light) }

        if !preview {
            store.pool.start()
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            if let button = statusItem?.button {
                let image = NSImage(systemSymbolName: "gauge.with.dots.needle.67percent", accessibilityDescription: "LLM Usage — Accounts and usage")
                image?.isTemplate = true
                button.image = image
                button.target = self
                button.action = #selector(togglePanel)
                button.toolTip = "LLM Usage · Accounts and usage"
            }
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
                Task { @MainActor in await self?.store.refreshStale() }
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown, self.panel.isVisible {
                if event.keyCode == 53 {
                    if self.store.pool.showingDevices { self.store.pool.showingDevices = false }
                    else if self.store.isSigningIn { self.store.cancelSignIn() }
                    else if self.store.showingEditor { self.store.closeEditor() }
                    else if self.store.showingSettings { self.store.showingSettings = false }
                    else if self.store.showingAccountDetails { self.store.showHome() }
                    else { self.hidePanel() }
                    return nil
                }
                if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "q" { NSApp.terminate(nil); return nil }
            }
            return event
        }
        store.onAccountConnected = { [weak self] in self?.showPanel() }
        store.resumePendingSignIn()
        showPanel(centered: preview)
        if preview, let index = arguments.firstIndex(of: "--window-id-file"), arguments.indices.contains(index + 1) {
            try? String(panel.windowNumber).write(toFile: arguments[index + 1], atomically: true, encoding: .utf8)
        }
    }

    @objc private func togglePanel() {
        if panel.isVisible { hidePanel() } else { showPanel() }
    }
    private func showPanel(centered: Bool = false) {
        if centered { panel.center() }
        else if let button = statusItem?.button, let window = button.window {
            let buttonFrame = window.convertToScreen(button.convert(button.bounds, to: nil))
            let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let x = min(max(buttonFrame.maxX - panel.frame.width + 7, visible.minX + 12), visible.maxX - panel.frame.width - 12)
            let y = max(visible.minY + 8, min(buttonFrame.minY - panel.frame.height - 9, visible.maxY - panel.frame.height - 8))
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        } else { panel.center() }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()
        if !arguments.contains("--preview") {
            if clickMonitor == nil {
                clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, !self.store.isSigningIn else { return }
                        self.hidePanel()
                    }
                }
            }
            Task { await store.refreshStale() }
        }
    }
    private func hidePanel() {
        panel.orderOut(nil)
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor); self.clickMonitor = nil }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        return false
    }
    func applicationDidResignActive(_ notification: Notification) {
        if !arguments.contains("--preview"), !store.isSigningIn { hidePanel() }
    }
    func applicationWillTerminate(_ notification: Notification) {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        refreshTimer?.invalidate()
        store.shutdown()
    }
}
