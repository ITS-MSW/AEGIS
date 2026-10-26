import AppKit
import SwiftUI
import Combine

final class NotchWindowController: NSWindowController {
    private let sessionStore: SessionStore
    private var cancellables = Set<AnyCancellable>()

    static var compactSize: NSSize {
        guard ScreenDetector.hasNotch else { return NSSize(width: 230, height: 32) }
        return NSSize(width: max(280, ScreenDetector.notchWidth + 100), height: ScreenDetector.notchHeight)
    }

    init(sessionStore: SessionStore, settingsStore: SettingsStore) {
        self.sessionStore = sessionStore
        let frame = ScreenDetector.notchPanelFrame(panelSize: Self.compactSize)
        let panel = NotchPanel(contentRect: frame)
        super.init(window: panel)

        let hostingView = NSHostingView(rootView: NotchContentView(
            sessionStore: sessionStore,
            settingsStore: settingsStore
        ))
        hostingView.sizingOptions = []
        hostingView.frame = NSRect(origin: .zero, size: frame.size)
        hostingView.autoresizingMask = [.width, .height]

        // A container avoids NSHostingView re-entering AppKit's window constraints.
        let container = NSView(frame: hostingView.frame)
        container.autoresizesSubviews = true
        container.addSubview(hostingView)
        panel.contentView = container
        panel.isReleasedWhenClosed = false

        sessionStore.$sessions
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reconcileWindowPresence() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.repositionWindow() }
            .store(in: &cancellables)

        reconcileWindowPresence()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    private func reconcileWindowPresence() {
        guard let panel = window else { return }
        repositionWindow()
        if NotchPresencePolicy.shouldShow(activeSessionCount: sessionStore.activeSessions.count) {
            if !panel.isVisible {
                panel.orderFrontRegardless()
                (panel as? NotchPanel)?.applyNotchLevel()
            }
        } else {
            panel.orderOut(nil)
        }
    }

    private func repositionWindow() {
        window?.setFrame(ScreenDetector.notchPanelFrame(panelSize: Self.compactSize), display: true)
    }
}

enum NotchPresencePolicy {
    static func shouldShow(activeSessionCount: Int) -> Bool {
        activeSessionCount > 0
    }
}
