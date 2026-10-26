import XCTest
@testable import Aegis

final class EphemeralSessionTests: XCTestCase {
    @MainActor
    func testEphemeralActivityNeverCreatesSessionsEvenWithSubagentsEnabled() {
        let store = SessionStore()
        store.setShowsSubagents(true)
        for event in ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop"] {
            store.handleMessage(BridgeMessage(sessionId: "internal", hookEvent: event, source: "codex", isEphemeral: true))
            XCTAssertTrue(store.sessions.isEmpty)
        }
        store.handleMessage(BridgeMessage(sessionId: "user", hookEvent: "UserPromptSubmit", source: "codex"))
        XCTAssertNotNil(store.activeSessions["user"])
    }

    @MainActor
    func testEphemeralPermissionRemainsVisibleThenIsRemovedOnProgress() {
        let store = SessionStore()
        store.handleMessage(BridgeMessage(sessionId: "internal", hookEvent: "PermissionRequest", toolName: "Bash", source: "codex", isEphemeral: true))
        XCTAssertEqual(store.sessions["internal"]?.status, .waitingPermission)
        store.handleMessage(BridgeMessage(sessionId: "internal", hookEvent: "PostToolUse", source: "codex"))
        XCTAssertNil(store.sessions["internal"])
    }
}
