import Combine
import XCTest
@testable import Aegis
import AegisBridgeSupport

final class SessionStorePublicationTests: XCTestCase {
    @MainActor
    func testHiddenSubagentPermissionRemainsVisibleUntilProviderProgress() {
        let store = SessionStore()

        store.handleMessage(
            message(event: "PermissionRequest", toolName: "Bash", parentSessionId: "parent")
        )

        XCTAssertEqual(store.sessions[Self.sessionId]?.status, .waitingPermission)
        store.handleMessage(message(event: "PostToolUse", toolName: "Bash", parentSessionId: "parent"))
        XCTAssertNil(store.sessions[Self.sessionId])
    }

    @MainActor
    func testCanonicalMessagesPublishOnceAndEventsObserveCommittedState() {
        let store = SessionStore()
        var publications = 0
        var observedStatuses: [SessionStatus] = []
        let publication = store.$sessions.dropFirst().sink { _ in publications += 1 }
        let events = store.onEvent.sink { event in
            switch event {
            case .sessionStarted(let id), .statusChanged(let id, _):
                if let status = store.sessions[id]?.status { observedStatuses.append(status) }
            default:
                break
            }
        }

        store.handleMessage(
            message(event: "UserPromptSubmit", userMessage: "Optimize it")
        )

        XCTAssertEqual(publications, 1)
        XCTAssertEqual(observedStatuses, [.thinking, .thinking])
        withExtendedLifetime([publication, events]) {}
    }

    @MainActor
    func testEveryCanonicalEventPathPublishesOnce() {
        let cases: [BridgeMessage] = [
            message(event: "SessionStart"),
            message(event: "UserPromptSubmit", userMessage: "Start"),
            message(event: "PreToolUse", toolName: "Read"),
            message(event: "PostToolUse", toolName: "Read"),
            message(event: "PermissionRequest", toolName: "Bash"),
            message(event: "Notification", assistantMessage: "Notice"),
            message(event: "SubagentStart"),
            message(event: "SubagentStop"),
            message(event: "PreCompact"),
            message(event: "Stop", assistantMessage: "Done"),
            message(event: "SessionEnd"),
        ]

        for (index, bridgeMessage) in cases.enumerated() {
            let store = SessionStore()
            var publications = 0
            let cancellable = store.$sessions.dropFirst().sink { _ in publications += 1 }

            store.handleMessage(bridgeMessage)

            XCTAssertEqual(publications, 1, "case \(index): \(bridgeMessage.hookEvent)")
            withExtendedLifetime(cancellable) {}
        }
    }

    @MainActor
    func testNativeQuestionPublishesOnce() {
        let store = SessionStore()
        var publications = 0
        let cancellable = store.$sessions.dropFirst().sink { _ in publications += 1 }
        let input = #"{"questions":[{"question":"Continue?","header":"Choice","options":[{"label":"Yes"}]}]}"#

        store.handleMessage(
            message(event: "PreToolUse", toolName: "request_user_input", toolInput: input)
        )

        XCTAssertEqual(publications, 1)
        XCTAssertEqual(store.sessions["publication-session"]?.status, .waitingPermission)
        XCTAssertTrue(store.sessions["publication-session"]?.executionState.waitingForUser ?? false)
        withExtendedLifetime(cancellable) {}
    }

    @MainActor
    func testProviderProgressResolvesWaitingStatusWithinOnePublication() {
        let store = SessionStore()
        store.handleMessage(
            message(event: "PermissionRequest", toolName: "Bash")
        )
        var publications = 0
        let publication = store.$sessions.dropFirst().sink { _ in publications += 1 }
        var progressed = false
        let events = store.onEvent.sink { event in
            if case .toolStarted = event { progressed = true }
        }

        store.handleMessage(message(event: "PreToolUse", toolName: "Bash"))

        XCTAssertEqual(publications, 1)
        XCTAssertTrue(progressed)
        XCTAssertEqual(store.sessions["publication-session"]?.status, .toolUse)
        XCTAssertFalse(store.sessions["publication-session"]?.executionState.waitingForUser ?? true)
        withExtendedLifetime([publication, events]) {}
    }

    @MainActor
    func testIgnoredMessagesAndDuplicateSuggestionsPublishNothing() {
        let store = SessionStore()
        store.handleMessage(message(event: "UserPromptSubmit", userMessage: "Start"))
        store.handleMessage(message(event: "Stop", assistantMessage: "Done"))
        var publications = 0
        let cancellable = store.$sessions.dropFirst().sink { _ in publications += 1 }

        store.handleMessage(message(event: "provider_raw_event"))
        store.handleMessage(
            message(event: "Stop", assistantMessage: #"{"suggestions":[{"title":"Next"}]}"#)
        )

        XCTAssertEqual(publications, 0)
        XCTAssertEqual(store.sessions["publication-session"]?.lastAssistantMessage, "Done")
        withExtendedLifetime(cancellable) {}
    }

    @MainActor
    func testThousandToolEventsProduceThousandPublications() {
        let store = SessionStore()
        var publications = 0
        var eventCount = 0
        let publication = store.$sessions.dropFirst().sink { _ in publications += 1 }
        let events = store.onEvent.sink { _ in eventCount += 1 }

        for index in 0..<1_000 {
            let event = index.isMultiple(of: 2) ? "PreToolUse" : "PostToolUse"
            store.handleMessage(message(event: event, toolName: "Read"))
        }

        XCTAssertEqual(publications, 1_000)
        XCTAssertEqual(eventCount, 1_001)
        withExtendedLifetime([publication, events]) {}
    }

    @MainActor
    func testActivityUpdatesAreEphemeralAndIgnoreLateOrDuplicateContent() {
        let store = SessionStore()
        store.handleMessage(message(event: "ActivityUpdate", activitySummary: "Too early"))
        XCTAssertNil(store.sessions[Self.sessionId])

        store.handleMessage(message(event: "UserPromptSubmit", userMessage: "Start"))
        store.handleMessage(message(event: "ActivityUpdate", activitySummary: "  Checking\nfiles  "))
        XCTAssertEqual(store.sessions[Self.sessionId]?.activitySummary, "Checking files")

        var publications = 0
        let cancellable = store.$sessions.dropFirst().sink { _ in publications += 1 }
        store.handleMessage(message(event: "ActivityUpdate", activitySummary: "Checking files"))
        XCTAssertEqual(publications, 0)

        store.handleMessage(message(event: "Stop", assistantMessage: "Done"))
        XCTAssertNil(store.sessions[Self.sessionId]?.activitySummary)
        store.handleMessage(message(event: "ActivityUpdate", activitySummary: "Too late"))
        XCTAssertNil(store.sessions[Self.sessionId]?.activitySummary)
        withExtendedLifetime(cancellable) {}
    }

    @MainActor
    func testToolActivityRemainsVisibleBetweenToolCalls() {
        let store = SessionStore()
        store.handleMessage(message(event: "UserPromptSubmit", userMessage: "Start"))
        store.handleMessage(message(event: "PreToolUse", toolName: "functions.exec"))

        XCTAssertEqual(store.sessions[Self.sessionId]?.status, .toolUse)
        XCTAssertEqual(store.sessions[Self.sessionId]?.activitySummary, "Running command")

        store.handleMessage(message(event: "PostToolUse", toolName: "functions.exec"))

        XCTAssertEqual(store.sessions[Self.sessionId]?.status, .thinking)
        XCTAssertEqual(store.sessions[Self.sessionId]?.activitySummary, "Running command")
    }

    private static let sessionId = "publication-session"

    private func message(
        event: String,
        userMessage: String? = nil,
        assistantMessage: String? = nil,
        toolName: String? = nil,
        toolInput: String? = nil,
        activitySummary: String? = nil,
        toolOutcome: ToolOutcome? = nil,
        parentSessionId: String? = nil
    ) -> BridgeMessage {
        BridgeMessage(
            sessionId: Self.sessionId,
            hookEvent: event,
            cwd: "/tmp/project",
            toolName: toolName,
            toolInput: toolInput,
            userMessage: userMessage,
            assistantMessage: assistantMessage,
            activitySummary: activitySummary,
            toolOutcome: toolOutcome,
            source: "codex",
            parentSessionId: parentSessionId
        )
    }
}
