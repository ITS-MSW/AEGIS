import Foundation

enum SessionStatus: String, Codable, Equatable {
    case idle
    case thinking
    case toolUse
    case waitingPermission
    case error
    case completed

    var displayText: String {
        switch self {
        case .idle: return "Idle"
        case .thinking: return "Thinking..."
        case .toolUse: return "Using tool"
        case .waitingPermission: return "Needs approval"
        case .error: return "Error"
        case .completed: return "Done"
        }
    }
}

struct SessionExecutionState: Equatable {
    var turnActive = false
    var activeSubagentCount = 0
    var waitingForUser = false

    var isConfirmedExecuting: Bool {
        !waitingForUser && (turnActive || activeSubagentCount > 0)
    }

    mutating func beginTurn() {
        turnActive = true
        activeSubagentCount = 0
        waitingForUser = false
    }

    mutating func recordProgress() {
        turnActive = true
        waitingForUser = false
    }

    mutating func beginSubagent() {
        activeSubagentCount += 1
        waitingForUser = false
    }

    mutating func endSubagent() {
        activeSubagentCount = max(0, activeSubagentCount - 1)
    }

    mutating func waitForUser() {
        waitingForUser = true
    }

    mutating func finish() {
        turnActive = false
        activeSubagentCount = 0
        waitingForUser = false
    }
}

struct Session: Identifiable {
    let id: String
    var cwd: String
    let startedAt: Date
    var status: SessionStatus
    var executionState = SessionExecutionState()
    var currentTool: String?
    var firstPrompt: String?
    var lastUserMessage: String?
    var lastAssistantMessage: String?
    /// Ephemeral, public progress for the active turn. Never persisted.
    var activitySummary: String?
    var effortLevel: String?
    var lastToolDurationMs: Int?
    var sessionTitle: String?
    /// Model metadata captured from provider events.
    var model: String?
    /// AI provider identifier.
    var source: String = "codex"
    /// Parent provider session when this session belongs to a child agent.
    var parentSessionId: String?
    var isEphemeral: Bool = false
    /// True when a provider watcher can independently reconcile this session's
    /// durable lifecycle. Hook-only sessions need an inactivity fallback
    /// because a failed provider call may never emit its closing hook.
    var isDurablyTracked: Bool = false
    /// Time of the most recent event from this session — used so the collapsed
    /// notch tracks the *currently active* session, not just whichever was opened first.
    var lastActivityAt: Date = .init()
    /// PID of the AI agent process. Used to detect when
    /// the agent has exited so we can clean up the session — agents don't
    /// always fire SessionEnd reliably (Codex doesn't, for example).
    var agentPid: Int?
    /// Recorded start time of `agentPid` (sec, usec). Used to detect PID
    /// reuse: kill(pid, 0) returning 0 isn't enough — the kernel can
    /// recycle pids in seconds. If the live process's start time doesn't
    /// match what we recorded, the original agent is gone (issue #29).
    var agentStartSec: Int?
    var agentStartUsec: Int?
    /// True once we've emitted `.sessionStarted` for this session — guards
    /// against double-emit when applyCodexThreads and the SessionStart hook
    /// both arrive (issue #37).
    var announced: Bool = false
    /// True when cwd is still the placeholder ("~") and any specific cwd
    /// from a later event should overwrite it (issue #38). Cleared on first
    /// real assignment.
    var cwdIsPlaceholder: Bool = true

    /// Resolved provider object for theming/grouping.
    var provider: AIProvider { AIProvider.from(source) }

    var projectName: String {
        (cwd as NSString).lastPathComponent
    }

    /// Preferred display name. Falls through three sources in order:
    ///   1. `sessionTitle` from the provider or Codex app-server.
    ///   2. The folder name from `cwd` if it looks like a real project (not the
    ///      user's home directory).
    ///   3. The first prompt the user sent, truncated. Better than showing the
    ///      home-folder name when Codex was launched from `~`.
    var displayName: String {
        if let title = sessionTitle, !title.isEmpty { return title }
        if isMeaningfulProjectFolder { return projectName }
        if let prompt = firstPrompt, !prompt.isEmpty {
            return Self.truncated(prompt)
        }
        return projectName
    }

    /// True when `cwd` isn't the user's home directory and isn't `/` —
    /// i.e. it points at a project we'd want to show in the title slot.
    private var isMeaningfulProjectFolder: Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return cwd != home && cwd != "/" && cwd != "~"
    }

    private static func truncated(_ s: String, max: Int = 40) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= max { return trimmed }
        return String(trimmed.prefix(max)) + "…"
    }

}

enum SessionActivitySummary {
    static func toolLabel(_ toolName: String) -> String {
        let normalized = toolName.lowercased()

        if normalized.contains("apply_patch") { return "Editing files" }
        if normalized.contains("exec") || normalized.contains("shell") { return "Running command" }
        if normalized.contains("view_image") { return "Viewing image" }
        if normalized.contains("imagegen") { return "Generating image" }
        if normalized.contains("web") || normalized.contains("browser") { return "Browsing the web" }
        if normalized.contains("read_mcp_resource") { return "Reading resource" }
        if normalized.contains("update_plan") { return "Updating plan" }
        if normalized.contains("spawn_agent") { return "Starting subagent" }
        if normalized.contains("send_message") { return "Messaging subagent" }
        if normalized.contains("wait") { return "Waiting for result" }

        let component = toolName
            .split(whereSeparator: { $0 == "." || $0 == "/" })
            .last
            .map(String.init) ?? toolName
        let words = component
            .replacingOccurrences(of: "__", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return words.isEmpty ? "Using tool" : "Using \(words)"
    }
}
