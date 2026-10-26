import Foundation
import AegisBridgeSupport

/// Incoming message from the bridge CLI.
struct BridgeMessage: Codable {
    let sessionId: String
    let hookEvent: String
    let cwd: String?
    let toolName: String?
    let toolInput: String?
    let notification: String?
    let userMessage: String?
    let assistantMessage: String?
    /// Short, public provider progress suitable for transient UI display.
    /// This must never contain private or encrypted reasoning payloads.
    let activitySummary: String?
    let effortLevel: String?
    let durationMs: Int?
    /// Structured provider result. Nil means the provider did not expose a
    /// trustworthy outcome; callers must not infer failure from output text.
    let toolOutcome: ToolOutcome?
    let sessionTitle: String?
    /// Identifier of the AI provider that fired this hook.
    /// Defaults to "codex" if the bridge doesn't stamp this field.
    let source: String?
    /// Parent session for provider-created child agents. Nil for root sessions.
    let parentSessionId: String?
    /// Provider explicitly reports that this session has no persistent transcript.
    let isEphemeral: Bool?
    /// PID of the agent process that spawned the bridge (getppid in the bridge).
    /// Used to detect when an agent exits without firing SessionEnd.
    let agentPid: Int?
    /// Model name the agent is using, captured from the hook payload.
    let model: String?

    init(
        sessionId: String,
        hookEvent: String,
        cwd: String? = nil,
        toolName: String? = nil,
        toolInput: String? = nil,
        notification: String? = nil,
        userMessage: String? = nil,
        assistantMessage: String? = nil,
        activitySummary: String? = nil,
        effortLevel: String? = nil,
        durationMs: Int? = nil,
        toolOutcome: ToolOutcome? = nil,
        sessionTitle: String? = nil,
        source: String? = nil,
        parentSessionId: String? = nil,
        isEphemeral: Bool? = nil,
        agentPid: Int? = nil,
        model: String? = nil
    ) {
        self.sessionId = sessionId
        self.hookEvent = hookEvent
        self.cwd = cwd
        self.toolName = toolName
        self.toolInput = toolInput
        self.notification = notification
        self.userMessage = userMessage
        self.assistantMessage = assistantMessage
        self.activitySummary = activitySummary
        self.effortLevel = effortLevel
        self.durationMs = durationMs
        self.toolOutcome = toolOutcome
        self.sessionTitle = sessionTitle
        self.source = source
        self.parentSessionId = parentSessionId
        self.isEphemeral = isEphemeral
        self.agentPid = agentPid
        self.model = model
    }

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case hookEvent = "hook_event"
        case cwd
        case toolName = "tool_name"
        case toolInput = "tool_input"
        case notification
        case userMessage = "user_message"
        case assistantMessage = "assistant_message"
        case activitySummary = "activity_summary"
        case effortLevel = "effort_level"
        case durationMs = "duration_ms"
        case toolOutcome = "tool_outcome"
        case sessionTitle = "session_title"
        case source
        case parentSessionId = "parent_session_id"
        case isEphemeral = "is_ephemeral"
        case agentPid = "agent_pid"
        case model
    }
}
