import Foundation
import Combine
import AegisBridgeSupport

enum SessionEvent {
    case sessionStarted(String)
    case sessionEnded(String)
    case statusChanged(String, SessionStatus)
    case toolStarted(String, String)
    case toolEnded(String, String, ToolOutcome?)
    case notification(String, String)
}

enum SessionExecutionEvent: Equatable {
    case began(String)
    case progressed(String)
    case ended(String)
}

enum SessionMessageOrigin: Equatable {
    case providerHook
    case durableProviderState
}

@MainActor
final class SessionStore: ObservableObject {
    private static let codexIdleThreshold: TimeInterval = 5 * 60
    private static let hookOnlyThinkingIdleThreshold: TimeInterval = 15 * 60
    private static let hookOnlyThinkingSources: Set<String> = ["hermes", "antigravity"]
    private static let silentActiveSessionLifetime: TimeInterval = 24 * 60 * 60

    @Published var sessions: [String: Session] = [:]

    let onEvent = PassthroughSubject<SessionEvent, Never>()
    let onExecutionEvent = PassthroughSubject<SessionExecutionEvent, Never>()

    private enum PostCommitEffect {
        case event(SessionEvent)
        case execution(SessionExecutionEvent)
        case scheduleRemoval(sessionId: String, delay: TimeInterval)
    }

    /// Polls every 5s to check whether the AI agent process is still alive.
    /// Cleaner than time-based cleanup because long idle sessions stay open
    /// while genuinely-exited sessions get removed quickly.
    private var processSweepTimer: Timer?

    /// In-flight removal tasks keyed by session id. A late event can cancel
    /// the pending removal and re-activate the session, instead of having
    /// the timer fire and silently delete a freshly-recreated session with
    /// the same id (issues #8, #9, #10).
    private var pendingRemovals: [String: Task<Void, Never>] = [:]
    private var showsSubagents = false

    init() {
        processSweepTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sweepClosedAgents() }
        }
    }

    deinit {
        processSweepTimer?.invalidate()
    }

    /// Marks sessions whose agent has exited as ended, then removes them.
    ///
    /// Three detection strategies, used in parallel:
    ///   1. PID probe via `kill(pid, 0)` — reliable for providers where the
    ///      hook bridge's `getppid()` returns the agent's own short-lived
    ///      process. Returns -1 with errno=ESRCH when the process is gone.
    ///   2. Codex-only inactivity timeout — Codex routes hooks through a
    ///      persistent `app-server` daemon (the bridge's parent is always
    ///      that long-lived process), so PID detection never fires. If a
    ///      Codex session goes 5+ minutes without ANY hook, we treat it as
    ///      ended. 5 minutes is conservative enough that an actively-used
    ///      session won't be killed even mid-tool-call.
    ///   3. Hook-only thinking timeout — Hermes background work and AntiGravity
    ///      windows can disappear before their closing hook fires. Durable
    ///      sessions retain their provider watcher, while hook-only sessions are
    ///      retired after 15 minutes without progress. Tool and approval states
    ///      remain exempt so long-running commands and user decisions stay visible.
    ///   4. Silent active-session lease — any provider can miss its closing event.
    ///      Thinking/tool states with no event for 24 hours are abandoned, while
    ///      approval states remain visible until the user resolves them.
    func sweepClosedAgents(at now: Date = Date()) {

        for (id, session) in sessions {
            guard session.status != .completed else { continue }

            var shouldClose = false

            // Strategy 1: PID probe — also check process start time so we
            // don't keep a dead session alive forever because the kernel
            // recycled the pid to some unrelated process (issue #29).
            if let pid = session.agentPid {
                let result = kill(pid_t(pid), 0)
                if result != 0 && errno == ESRCH {
                    shouldClose = true
                } else if let startSec = session.agentStartSec,
                          let startUsec = session.agentStartUsec,
                          let now = Self.processStartTime(pid: pid_t(pid)),
                          (Int(now.tv_sec) != startSec || Int(now.tv_usec) != startUsec) {
                    // PID is alive but it's a different process now.
                    shouldClose = true
                }
            }

            // Strategy 2: inactivity timeout (Codex only — PID is unreliable
            // because hooks route through a long-lived daemon). Skip when
            // a tool is in flight — Codex emits PreToolUse then nothing
            // until PostToolUse, and we'd kill the session mid-tool on
            // anything that takes more than 5 minutes (issue #11).
            if !shouldClose && session.source == "codex" && session.status == .idle {
                if now.timeIntervalSince(session.lastActivityAt) > Self.codexIdleThreshold {
                    shouldClose = true
                }
            }

            if !shouldClose,
               Self.hookOnlyThinkingSources.contains(session.source),
               !session.isDurablyTracked,
               session.status == .thinking,
               now.timeIntervalSince(session.lastActivityAt) > Self.hookOnlyThinkingIdleThreshold {
                Log.info("Hook session expired after inactivity source=\(session.source) session=\(id.prefix(8))")
                shouldClose = true
            }

            if !shouldClose,
               session.status == .thinking || session.status == .toolUse,
               now.timeIntervalSince(session.lastActivityAt) > Self.silentActiveSessionLifetime {
                // ponytail: 24h is the safety lease until every provider exposes authoritative task liveness.
                Log.info("Silent active session expired source=\(session.source) session=\(id.prefix(8))")
                shouldClose = true
            }

            if shouldClose {
                markCompletedAndScheduleRemoval(sessionId: id, after: 2.0)
            }
        }
    }

    // MARK: - Removal helpers

    /// Mark the session completed, emit `sessionEnded`, and schedule its
    /// removal after `delay`. A late hook arrival within `delay` cancels
    /// the removal and resurrects the session via `handleLateEvent`.
    private func markCompletedAndScheduleRemoval(sessionId: String, after delay: TimeInterval) {
        guard var session = sessions[sessionId], session.status != .completed else { return }
        let wasExecuting = session.executionState.isConfirmedExecuting
        session.status = .completed
        session.executionState.finish()
        sessions[sessionId] = session
        if wasExecuting {
            onExecutionEvent.send(.ended(sessionId))
        }
        onEvent.send(.sessionEnded(sessionId))
        scheduleRemoval(sessionId: sessionId, after: delay)
    }

    private func scheduleRemoval(sessionId: String, after delay: TimeInterval) {
        pendingRemovals[sessionId]?.cancel()
        pendingRemovals[sessionId] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            await MainActor.run {
                guard let self else { return }
                self.pendingRemovals.removeValue(forKey: sessionId)
                // Re-check completed — a brand-new session with the same id
                // Resumed or reused sessions will have status
                // reset to .idle / .thinking by ensureSession + handleMessage.
                if self.sessions[sessionId]?.status == .completed {
                    self.sessions.removeValue(forKey: sessionId)
                }
            }
        }
    }

    private func cancelPendingRemoval(sessionId: String) {
        pendingRemovals[sessionId]?.cancel()
        pendingRemovals.removeValue(forKey: sessionId)
    }

    func setShowsSubagents(_ showsSubagents: Bool) {
        self.showsSubagents = showsSubagents
        guard !showsSubagents else { return }
        for sessionId in sessions.values.compactMap({ session in
            session.parentSessionId != nil && session.status != .waitingPermission
                ? session.id
                : nil
        }) {
            removeHiddenSubagent(sessionId: sessionId)
        }
    }

    private func removeHiddenSubagentIfSettled(sessionId: String) {
        guard let session = sessions[sessionId],
              session.isEphemeral || (!showsSubagents && session.parentSessionId != nil),
              session.status != .waitingPermission else { return }
        removeHiddenSubagent(sessionId: sessionId)
    }

    private func removeHiddenSubagent(sessionId: String) {
        cancelPendingRemoval(sessionId: sessionId)
        if sessions[sessionId]?.executionState.isConfirmedExecuting == true {
            onExecutionEvent.send(.ended(sessionId))
        }
        sessions.removeValue(forKey: sessionId)
    }

    /// Returns the start time of the process at `pid`, or nil if it's
    /// unreadable. Used to detect PID reuse alongside `kill(pid, 0)`.
    private static func processStartTime(pid: pid_t) -> timeval? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let result = withUnsafeMutablePointer(to: &mib[0]) { mibPtr in
            sysctl(mibPtr, 4, &info, &size, nil, 0)
        }
        if result == 0 {
            return info.kp_proc.p_starttime
        }
        return nil
    }

    var activeSessions: [String: Session] {
        sessions.filter { _, session in
            switch session.status {
            case .thinking, .toolUse, .waitingPermission, .error:
                return true
            case .idle, .completed:
                return false
            }
        }
    }

    /// The canonical events the store understands. Every provider bridge
    /// normalizes its native vocabulary to one of these before sending; a
    /// a message arriving with a raw, un-normalized name bypassed our
    /// normalization and belongs to
    /// a foreign/misconfigured integration sharing the socket — drop it so it
    /// can't create phantom sessions or clobber a correctly-attributed one.
    private static let canonicalEvents: Set<String> = [
        "SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse",
        "PermissionRequest", "Stop", "Notification", "SubagentStart", "SubagentStop", "PreCompact",
        "ActivityUpdate",
    ]

    func handleMessage(
        _ message: BridgeMessage,
        origin: SessionMessageOrigin = .providerHook
    ) {
        let sessionId = message.sessionId
        let parentSessionId = message.parentSessionId ?? sessions[sessionId]?.parentSessionId
        let isEphemeral = message.isEphemeral ?? sessions[sessionId]?.isEphemeral ?? false
        let hasPendingAttention = sessions[sessionId].map {
            $0.status == .waitingPermission
        } ?? false
        if (isEphemeral || (!showsSubagents && parentSessionId != nil)) && !hasPendingAttention && !Self.isAttentionRequest(message) {
            if sessions[sessionId] != nil {
                removeHiddenSubagent(sessionId: sessionId)
            }
            return
        }
        guard Self.canonicalEvents.contains(message.hookEvent) else {
            Log.info("Ignoring non-canonical event '\(message.hookEvent)' from source=\(message.source ?? "?") session=\(sessionId.prefix(8))")
            return
        }

        if message.hookEvent == "ActivityUpdate" {
            guard let existing = sessions[sessionId],
                  existing.status == .thinking || existing.status == .toolUse,
                  let summary = Self.normalizedActivitySummary(message.activitySummary),
                  summary != existing.activitySummary else { return }
        }

        if message.hookEvent == "Stop",
           let assistantMessage = message.assistantMessage,
           Self.isSuggestionsBlob(assistantMessage),
           sessions[sessionId]?.status == .idle {
            return
        }

        let now = Date()
        var effects: [PostCommitEffect] = []
        var session: Session
        if let existing = sessions[sessionId] {
            session = existing
            if let cwd = message.cwd, !cwd.isEmpty, session.cwdIsPlaceholder {
                session.cwd = cwd
                session.cwdIsPlaceholder = false
            }
        } else {
            session = Session(
                id: sessionId,
                cwd: message.cwd ?? "~",
                startedAt: now,
                status: .idle,
                source: message.source ?? "codex",
                parentSessionId: message.parentSessionId
            )
            session.cwdIsPlaceholder = message.cwd == nil
            session.announced = true
            effects.append(.event(.sessionStarted(sessionId)))
        }

        if let source = message.source {
            session.source = source
        }
        if let parentSessionId = message.parentSessionId {
            session.parentSessionId = parentSessionId
        }
        session.isEphemeral = isEphemeral
        if origin == .durableProviderState {
            session.isDurablyTracked = true
        }

        // A late buffered hook may arrive after we've marked a session
        // .completed and scheduled removal. Cancel the pending removal so
        // the brand-new session (for example, Codex thread reuse) isn't
        // deleted out from under us, and reset .completed back to .idle so
        // the per-event switch below can transition normally (issue #10).
        if session.status == .completed {
            cancelPendingRemoval(sessionId: sessionId)
            session.status = .idle
        }
        // Stamp activity time on every event so the collapsed notch tracks
        // whatever provider is most recently doing something.
        session.lastActivityAt = now
        let wasExecuting = session.executionState.isConfirmedExecuting
        var recordedExecutionProgress = false

        // Always update effort level if present (it's on most hooks)
        if let effort = message.effortLevel {
            session.effortLevel = effort
        }
        // Stamp the model whenever the hook carries one.
        if let m = message.model, !m.isEmpty {
            session.model = m
        }
        // Always update session title if present
        if let title = message.sessionTitle, !title.isEmpty {
            session.sessionTitle = title
        }
        // Capture the agent PID — used to detect when the agent exits.
        // Also stamp its start time so PID reuse can be detected later
        // (issue #29).
        if let pid = message.agentPid, pid > 0 {
            if session.agentPid != pid {
                session.agentPid = pid
                if let start = Self.processStartTime(pid: pid_t(pid)) {
                    session.agentStartSec = Int(start.tv_sec)
                    session.agentStartUsec = Int(start.tv_usec)
                }
            }
        }

        switch message.hookEvent {
        case "SessionStart":
            session.status = .idle
            session.activitySummary = nil
            session.executionState.finish()
            // ensureSession already emitted .sessionStarted for first-time
            // creates. Suppress the redundant SessionStart-hook emit so
            // subscribers (sounds, metrics) see exactly one start per id
            // (issue #37).
            if !session.announced {
                session.announced = true
                effects.append(.event(.sessionStarted(sessionId)))
            }

        case "SessionEnd":
            session.status = .completed
            session.activitySummary = nil
            session.executionState.finish()
            effects.append(.event(.sessionEnded(sessionId)))
            effects.append(.scheduleRemoval(sessionId: sessionId, delay: 5.0))

        case "UserPromptSubmit":
            let userMsg = message.userMessage ?? message.toolInput
            if let msg = userMsg {
                session.lastUserMessage = msg
                if session.firstPrompt == nil {
                    session.firstPrompt = msg
                }
            }
            session.status = .thinking
            session.currentTool = nil
            session.activitySummary = nil
            session.executionState.beginTurn()
            recordedExecutionProgress = true
            effects.append(.event(.statusChanged(sessionId, .thinking)))

        case "PreToolUse":
            let toolName = message.toolName ?? "unknown"
            session.status = .toolUse
            session.currentTool = toolName
            session.activitySummary = SessionActivitySummary.toolLabel(toolName)
            session.executionState.recordProgress()
            recordedExecutionProgress = true
            effects.append(.event(.toolStarted(sessionId, toolName)))

            if Self.isNativeQuestion(message) {
                session.status = .waitingPermission
                session.executionState.waitForUser()
            }

        case "PostToolUse":
            let toolName = message.toolName ?? "unknown"
            session.status = .thinking
            session.currentTool = nil
            session.executionState.recordProgress()
            recordedExecutionProgress = true
            session.lastToolDurationMs = message.durationMs
            // Don't update lastAssistantMessage from tool output
            effects.append(.event(.toolEnded(sessionId, toolName, message.toolOutcome)))

        case "ActivityUpdate":
            session.activitySummary = Self.normalizedActivitySummary(message.activitySummary)
            session.executionState.recordProgress()
            recordedExecutionProgress = true

        case "PermissionRequest":
            // Observation only: the provider owns the prompt and its answer.
            session.status = .waitingPermission
            session.executionState.waitForUser()
            effects.append(.event(.statusChanged(sessionId, .waitingPermission)))

        case "Stop":
            // Codex emits its follow-up suggestions as a SEPARATE Stop whose
            // assistant_message is a raw `{"suggestions":[…]}` object — never the
            // real reply. Don't render that JSON, and if the turn already
            // finished (the real reply's Stop already fired), drop it entirely so
            // it doesn't publish a duplicate completion.
            if let msg = message.assistantMessage, Self.isSuggestionsBlob(msg) {
                // otherwise complete the turn but keep the prior reply (if any)
            } else if let msg = message.assistantMessage {
                session.lastAssistantMessage = msg
            }
            session.status = .idle
            session.currentTool = nil
            session.activitySummary = nil
            session.executionState.finish()
            effects.append(.event(.statusChanged(sessionId, .idle)))

        case "Notification":
            if let msg = message.assistantMessage {
                session.lastAssistantMessage = msg
            }
            let text = message.notification ?? ""
            effects.append(.event(.notification(sessionId, text)))

        case "SubagentStart":
            session.currentTool = "Agent"
            session.activitySummary = "Working with subagent"
            session.executionState.beginSubagent()
            recordedExecutionProgress = true
            effects.append(.event(.toolStarted(sessionId, "Agent")))

        case "SubagentStop":
            session.currentTool = nil
            session.activitySummary = "Subagent finished"
            session.executionState.endSubagent()
            recordedExecutionProgress = true
            effects.append(.event(.toolEnded(sessionId, "Agent", nil)))

        case "PreCompact":
            session.executionState.recordProgress()
            recordedExecutionProgress = true

        default:
            break
        }

        let isExecuting = session.executionState.isConfirmedExecuting
        if !wasExecuting && isExecuting {
            effects.append(.execution(.began(sessionId)))
        } else if wasExecuting && !isExecuting {
            effects.append(.execution(.ended(sessionId)))
        } else if isExecuting && recordedExecutionProgress {
            effects.append(.execution(.progressed(sessionId)))
        }

        sessions[sessionId] = session

        for effect in effects {
            switch effect {
            case .event(let event):
                onEvent.send(event)
            case .execution(let event):
                onExecutionEvent.send(event)
            case .scheduleRemoval(let sessionId, let delay):
                scheduleRemoval(sessionId: sessionId, after: delay)
            }
        }
        removeHiddenSubagentIfSettled(sessionId: sessionId)
    }

    private static func isAttentionRequest(_ message: BridgeMessage) -> Bool {
        if message.hookEvent == "PermissionRequest" { return true }
        return message.hookEvent == "PreToolUse" && isNativeQuestion(message)
    }

    private static func isNativeQuestion(_ message: BridgeMessage) -> Bool {
        let source = message.source ?? "codex"
        return (source == "codex" && message.toolName == "request_user_input")
            || (source == "hermes" && message.toolName == "clarify")
    }

    private static func normalizedActivitySummary(_ value: String?) -> String? {
        guard let value else { return nil }
        let flattened = value
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !flattened.isEmpty else { return nil }
        return String(flattened.prefix(600))
    }

    /// Codex's "suggested follow-ups" arrive as an assistant_message that's a raw
    /// JSON object `{"suggestions":[{"title":…,"description":…}]}` — never a reply
    /// to display. Ignore it once the turn has already finished.
    private static func isSuggestionsBlob(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("{"), t.contains("\"suggestions\"") else { return false }
        guard let data = t.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return obj["suggestions"] != nil
    }

}
