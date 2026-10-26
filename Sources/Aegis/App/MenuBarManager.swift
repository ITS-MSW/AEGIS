import AppKit
import SwiftUI

extension Notification.Name {
    static let openSettings = Notification.Name("Aegis.openSettings")
}

@MainActor
final class MenuBarManager: NSObject {
    private var statusItem: NSStatusItem?
    private let settingsStore: SettingsStore
    private let onQuit: () -> Void
    private let onReloadSounds: () -> Void
    private let onPreviewEvent: (SoundEvent) -> Void
    private let onPreviewProfile: (SoundProfile) -> Void
    private let onPreviewFile: (String) -> Void
    private let onShowWelcome: () -> Void
    private let onShowWhatsNew: () -> Void
    private var settingsWindow: NSWindow?

    init(settingsStore: SettingsStore, onReloadSounds: @escaping () -> Void, onPreviewEvent: @escaping (SoundEvent) -> Void, onPreviewProfile: @escaping (SoundProfile) -> Void, onPreviewFile: @escaping (String) -> Void, onShowWelcome: @escaping () -> Void, onShowWhatsNew: @escaping () -> Void, onQuit: @escaping () -> Void) {
        self.settingsStore = settingsStore
        self.onReloadSounds = onReloadSounds
        self.onPreviewEvent = onPreviewEvent
        self.onPreviewProfile = onPreviewProfile
        self.onPreviewFile = onPreviewFile
        self.onShowWelcome = onShowWelcome
        self.onShowWhatsNew = onShowWhatsNew
        self.onQuit = onQuit
        super.init()
        setupStatusItem()
        NotificationCenter.default.addObserver(self, selector: #selector(openSettings), name: .openSettings, object: nil)
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "terminal.fill", accessibilityDescription: "Aegis")
            button.image?.size = NSSize(width: 16, height: 16)
        }

        let menu = NSMenu()
        menu.autoenablesItems = false

        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
        let titleItem = NSMenuItem(title: "Aegis v\(version)", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        menu.addItem(NSMenuItem.separator())

        let soundItem = NSMenuItem(title: "Sound Effects", action: #selector(toggleSound), keyEquivalent: "s")
        soundItem.target = self
        soundItem.state = settingsStore.soundEnabled ? .on : .off
        menu.addItem(soundItem)

        menu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let installItem = NSMenuItem(title: "Install Hooks", action: #selector(installHooks), keyEquivalent: "")
        installItem.target = self
        menu.addItem(installItem)

        let whatsNewItem = NSMenuItem(title: "What's New", action: #selector(showWhatsNew), keyEquivalent: "")
        whatsNewItem.target = self
        menu.addItem(whatsNewItem)

        let welcomeItem = NSMenuItem(title: "Welcome", action: #selector(showWelcome), keyEquivalent: "")
        welcomeItem.target = self
        menu.addItem(welcomeItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit Aegis", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
    }

    @objc private func toggleSound() {
        settingsStore.soundEnabled.toggle()
        if let menu = statusItem?.menu,
           let item = menu.items.first(where: { $0.action == #selector(toggleSound) }) {
            item.state = settingsStore.soundEnabled ? .on : .off
        }
    }

    @objc private func openSettings() {
        if let existing = settingsWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = SettingsView(settingsStore: settingsStore, onReloadSounds: onReloadSounds, onPreviewEvent: onPreviewEvent, onPreviewProfile: onPreviewProfile, onPreviewFile: onPreviewFile)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 580),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSHostingView(rootView: view)
        window.title = "Aegis Settings"
        window.center()
        window.isReleasedWhenClosed = false
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func installHooks() {
        // Re-run the same supported-provider installers used at launch.
        _ = CodexInstaller.install()
        _ = ProviderInstaller.installAll()

        let alert = NSAlert()
        alert.messageText = "Hooks installed"
        alert.informativeText = "Re-installed hooks for every detected agent. If an agent was already running, restart it to pick them up."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func showWhatsNew() {
        onShowWhatsNew()
    }

    @objc private func showWelcome() {
        onShowWelcome()
    }

    @objc private func quit() {
        onQuit()
    }
}
