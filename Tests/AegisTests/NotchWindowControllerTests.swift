import XCTest
@testable import Aegis

@MainActor
final class NotchWindowControllerTests: XCTestCase {
    func testNewSessionCannotRevealAStaleExpandedFrame() {
        let sessionStore = SessionStore()
        let settingsStore = SettingsStore()
        let controller = NotchWindowController(
            sessionStore: sessionStore,
            settingsStore: settingsStore
        )
        guard let panel = controller.window else {
            return XCTFail("Expected notch panel")
        }

        let screen = ScreenDetector.notchScreen.frame
        panel.setFrame(
            NSRect(
                x: screen.midX - 600 / 2,
                y: screen.maxY - 240,
                width: 600,
                height: 240
            ),
            display: false
        )

        sessionStore.handleMessage(
            BridgeMessage(
                sessionId: "new-session",
                hookEvent: "UserPromptSubmit",
                cwd: "/tmp/project",
                userMessage: "Start the run",
                source: "codex"
            )
        )
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(panel.frame.size, NotchWindowController.compactSize)
    }
}
