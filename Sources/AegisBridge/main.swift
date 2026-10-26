import Foundation
import AegisBridgeSupport

// MARK: - Aegis Bridge
// Reads hook JSON from a supported coding agent via stdin,
// maps to Aegis format, sends to the app via Unix domain socket.
// Events are observations only; prompts and decisions stay with the provider.
//
// Usage: aegis-bridge [--source <id>]   (default --source codex)

let socketPath = "/tmp/aegis.sock"

// Parse CLI args: optional `--source <id>` flag identifies which AI agent
// the hook came from. Codex is the default for direct bridge invocations.
var providerSource = "codex"
var eventTag: String? = nil
do {
    var i = 1
    let args = CommandLine.arguments
    while i < args.count {
        if args[i] == "--source" && i + 1 < args.count {
            providerSource = args[i + 1]
            i += 2
        } else if args[i] == "--event" && i + 1 < args.count {
            // Providers whose stdin omits the event name pass it here.
            eventTag = args[i + 1]
            i += 2
        } else {
            i += 1
        }
    }
}

// Read stdin
let inputData = FileHandle.standardInput.readDataToEndOfFile()
guard !inputData.isEmpty else { exit(1) }

/// Some agents (notably Hermes) emit JSON with RAW control characters — literal
/// newlines/tabs inside string values (e.g. a multi-line assistant_response or a
/// growing conversation_history) that they fail to escape. That makes the whole
/// payload invalid JSON, so the event is dropped and the session hangs (e.g.
/// "infinite thinking" because the Stop never arrives). Re-escape control bytes
/// that occur *inside strings*; structural whitespace between tokens is untouched.
func sanitizeControlChars(_ data: Data) -> Data {
    var out = [UInt8](); out.reserveCapacity(data.count + 16)
    var inString = false, escaped = false
    for b in data {
        if escaped { out.append(b); escaped = false; continue }
        if inString {
            switch b {
            case 0x5C: out.append(b); escaped = true            // backslash → next byte is literal
            case 0x22: out.append(b); inString = false          // closing quote
            case 0x08: out.append(contentsOf: [0x5C, 0x62])     // \b
            case 0x09: out.append(contentsOf: [0x5C, 0x74])     // \t
            case 0x0A: out.append(contentsOf: [0x5C, 0x6E])     // \n
            case 0x0C: out.append(contentsOf: [0x5C, 0x66])     // \f
            case 0x0D: out.append(contentsOf: [0x5C, 0x72])     // \r
            case 0x00...0x1F: out.append(contentsOf: Array(String(format: "\\u%04x", b).utf8))
            default: out.append(b)
            }
        } else {
            if b == 0x22 { inString = true }
            out.append(b)
        }
    }
    return Data(out)
}

// Parse the hook payload. Fall back to a control-char sanitize pass for agents
// that emit raw newlines inside JSON strings.
let payload: [String: Any]
if let p = try? JSONSerialization.jsonObject(with: inputData) as? [String: Any] {
    payload = p
} else if let p = try? JSONSerialization.jsonObject(with: sanitizeControlChars(inputData)) as? [String: Any] {
    payload = p
} else {
    fputs("aegis-bridge: invalid JSON on stdin\n", stderr)
    exit(1)
}

// Determine the raw event name. Most CLIs put it in "hook_event_name";
// Some providers omit it and pass it via --event. Then normalize each
// provider's event vocabulary to OUR canonical set so SessionStore — which
// only understands the canonical names — works unchanged.
let rawEvent = payload["hook_event_name"] as? String
    ?? payload["hook_event"] as? String
    ?? payload["type"] as? String
    ?? eventTag
    ?? "Notification"

// Per-source event-name normalization. Codex and OpenCode already emit the
// canonical vocabulary.
let eventNormalization: [String: [String: String]] = [
    // Hermes' turn cycle is driven by the
    // LLM-call events: pre_llm_call carries `user_message` (prompt → thinking),
    // post_llm_call carries `assistant_response` (reply → idle).
    // on_session_start registers the session; on_session_end is ignored (the PID
    // sweep handles real teardown — mapping it to SessionEnd removed the session
    // every turn). subagent_stop tracks delegations.
    "hermes": [
        "on_session_start": "SessionStart", "on_session_end": "skip",
        "pre_llm_call": "UserPromptSubmit", "post_llm_call": "Stop",
        "pre_tool_call": "PreToolUse", "post_tool_call": "PostToolUse",
        "subagent_stop": "SubagentStop",
    ],
    // Google AntiGravity (~/.gemini/config/hooks.json). PreInvocation = turn
    // start; PreToolUse/PostToolUse/Stop are already canonical (passthrough).
    "antigravity": [
        "PreInvocation": "UserPromptSubmit", "PostInvocation": "skip",
    ],
]
let hookEvent = eventNormalization[providerSource]?[rawEvent] ?? rawEvent
// Events outside the canonical model are dropped silently.
if hookEvent == "skip" { exit(0) }

// Some CLIs use camelCase identifiers or omit one entirely. Fall
// back to a STABLE per-process id — a random UUID would spawn a new session
// entry on every event.
let sessionId = (payload["session_id"] as? String)
    ?? (payload["sessionId"] as? String)
    ?? (payload["conversationId"] as? String)        // AntiGravity
    ?? "\(providerSource)-\(getppid())"
let parentSessionId = (payload["parent_session_id"] as? String)
    ?? (payload["parentSessionId"] as? String)
    ?? (payload["parent_thread_id"] as? String)
    ?? (payload["parentID"] as? String)
// AntiGravity's tool payload: { toolCall: { name, args: { CommandLine, Cwd } },
// workspacePaths: [...] } — no top-level cwd/tool_name/tool_input.
let agToolCall = payload["toolCall"] as? [String: Any]
let agArgs = agToolCall?["args"] as? [String: Any]
let cwd = (payload["cwd"] as? String)
    ?? (agArgs?["Cwd"] as? String)
    ?? (payload["workspacePaths"] as? [String])?.first

// Extract the tool name from the provider payload.
let toolName = payload["tool_name"] as? String ?? payload["toolName"] as? String
    ?? (agToolCall?["name"] as? String)

// Extract tool input as a string summary for session tracking.
var toolInputStr: String? = nil
let normalizedToolInput = payload["tool_input"] as? [String: Any]
if let toolInput = normalizedToolInput {
    if let cmd = toolInput["command"] as? String {
        toolInputStr = cmd
    } else if let fp = toolInput["file_path"] as? String {
        toolInputStr = fp
    } else if let url = toolInput["url"] as? String {
        toolInputStr = url
    } else if let pattern = toolInput["pattern"] as? String {
        toolInputStr = pattern
    } else if let desc = toolInput["description"] as? String {
        toolInputStr = desc
    } else {
        if let data = try? JSONSerialization.data(withJSONObject: toolInput, options: []) {
            toolInputStr = String(data: data, encoding: .utf8)
        }
    }
} else if let toolInput = payload["tool_input"] as? String {
    toolInputStr = toolInput
}
// Accept a top-level command when a provider doesn't nest tool input.
if toolInputStr == nil, let topCommand = payload["command"] as? String {
    toolInputStr = topCommand
}
// AntiGravity's shell tool: toolCall.args.CommandLine.
if toolInputStr == nil, let cl = agArgs?["CommandLine"] as? String {
    toolInputStr = cl
}
// Extract user and assistant messages. AntiGravity puts both only in its
// transcript.jsonl.
let agTranscriptPath = payload["transcriptPath"] as? String ?? payload["transcript_path"] as? String

let userMessage: String? = {
    if hookEvent == "UserPromptSubmit" {
        // AntiGravity carries no prompt field — read it from the transcript.
        if providerSource == "antigravity", let p = agTranscriptPath {
            return agUserRequestFromTranscript(p)
        }
        // Hermes' pre_llm_call carries the prompt as `user_message`, possibly
        // nested under `extra` — check both.
        let hermesExtra = payload["extra"] as? [String: Any]
        return payload["prompt"] as? String ?? payload["query"] as? String
            ?? payload["user_prompt"] as? String ?? payload["message"] as? String
            ?? payload["input"] as? String ?? payload["text"] as? String
            ?? payload["user_message"] as? String              // Hermes (top-level)
            ?? hermesExtra?["user_message"] as? String          // Hermes (in extra)
    }
    return nil
}()

let assistantMessage: String? = {
    if hookEvent == "Stop" {
        // AntiGravity carries no reply field — read it from the transcript.
        if providerSource == "antigravity", let p = agTranscriptPath {
            return agAssistantFromTranscript(p)
        }
        // Codex puts the reply in `assistant_message` (NOT last_assistant_message).
        // In plan mode that field is null and the reply (a <proposed_plan> block)
        // lives only in the rollout transcript — fall back to reading it there.
        if providerSource == "codex" {
            if let m = payload["assistant_message"] as? String, !m.isEmpty { return m }
            if let path = codexTranscriptPath(sessionId: sessionId) {
                return codexAssistantFromTranscript(path)
            }
            return nil
        }
        // Hermes' post_llm_call carries the reply as `assistant_response`,
        // possibly nested under `extra` — check both.
        let hermesExtra = payload["extra"] as? [String: Any]
        return payload["last_assistant_message"] as? String
            ?? payload["assistant_message"] as? String
            ?? payload["assistant_response"] as? String          // Hermes (top-level)
            ?? hermesExtra?["assistant_response"] as? String      // Hermes (in extra)
    }
    return nil
}()

/// Codex stores a per-session rollout transcript at
/// ~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<sessionId>.jsonl. Find it by the
/// id suffix in the filename. Only called when the Stop hook omitted the reply
/// (Codex plan mode), so the directory walk runs rarely.
func codexTranscriptPath(sessionId: String?) -> String? {
    guard let sessionId, !sessionId.isEmpty else { return nil }
    let base = (NSHomeDirectory() as NSString).appendingPathComponent(".codex/sessions")
    guard let en = FileManager.default.enumerator(atPath: base) else { return nil }
    let suffix = "-\(sessionId).jsonl"
    for case let rel as String in en where rel.hasSuffix(suffix) {
        return (base as NSString).appendingPathComponent(rel)
    }
    return nil
}

// Build the message for Aegis
var message: [String: Any] = [
    "session_id": sessionId,
    "hook_event": hookEvent,
    "source": providerSource,
]
if let cwd { message["cwd"] = cwd }
if providerSource == "codex", payload["transcript_path"] is NSNull {
    message["is_ephemeral"] = true
}
if let parentSessionId { message["parent_session_id"] = parentSessionId }
if let toolName { message["tool_name"] = toolName }
if let toolInputStr { message["tool_input"] = toolInputStr }

// Capture our parent PID. The bridge is launched directly by the AI agent
// (the launcher script `exec`s into the bridge, so getppid() returns the
// agent itself). The app uses this to detect when the agent has exited so
// the session can be removed from the notch.
message["agent_pid"] = Int(getppid())
if let userMessage { message["user_message"] = userMessage }
if let assistantMessage { message["assistant_message"] = assistantMessage }
if let sessionTitle = payload["session_title"] as? String, !sessionTitle.isEmpty {
    message["session_title"] = sessionTitle
}
if let effort = payload["effort"] as? [String: Any], let level = effort["level"] as? String {
    message["effort_level"] = level
}
if let durationMs = payload["duration_ms"] as? Int { message["duration_ms"] = durationMs }
if hookEvent == "PostToolUse" {
    let directOutcome = StructuredToolOutcomeDetector.namedOutcome(payload["tool_outcome"])
        ?? StructuredToolOutcomeDetector.namedOutcome(payload["status"])
    let structuredOutcome = ["result", "tool_response", "toolResponse", "output"]
        .compactMap { payload[$0] }
        .compactMap { StructuredToolOutcomeDetector.explicitOutcome(from: $0) }
        .first
    if let outcome = directOutcome ?? structuredOutcome {
        message["tool_outcome"] = outcome.rawValue
    }
}
// Codex emits `model` at the top level.
if let model = payload["model"] as? String, !model.isEmpty {
    message["model"] = model
}

// Serialize
guard let messageData = try? JSONSerialization.data(withJSONObject: message) else { exit(1) }

// SIGPIPE → ignored. We'd rather have write() return EPIPE so we can
// exit cleanly than have the kernel deliver a signal we don't handle.
signal(SIGPIPE, SIG_IGN)

// Connect to Unix socket
let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0 else { exit(1) }

// Per-socket SIGPIPE suppression — belt-and-braces with the signal handler.
var noSigPipe: Int32 = 1
setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
let pathBytes = Array(socketPath.utf8)
withUnsafeMutableBytes(of: &addr.sun_path) { rawPtr in
    for i in 0..<min(pathBytes.count, rawPtr.count - 1) {
        rawPtr[i] = pathBytes[i]
    }
}

let connected = withUnsafePointer(to: &addr) { ptr in
    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
        connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
}

guard connected == 0 else {
    close(fd)
    exit(1)
}

// MARK: - Framed I/O helpers

func writeAll(fd: Int32, bytes: UnsafePointer<UInt8>, count: Int) -> Bool {
    var sent = 0
    while sent < count {
        let n = write(fd, bytes.advanced(by: sent), count - sent)
        if n > 0 {
            sent += n
        } else if errno == EINTR {
            continue
        } else {
            return false
        }
    }
    return true
}

func writeFramed(fd: Int32, payload: Data) -> Bool {
    let len = UInt32(payload.count)
    let header: [UInt8] = [
        UInt8((len >> 24) & 0xFF),
        UInt8((len >> 16) & 0xFF),
        UInt8((len >> 8) & 0xFF),
        UInt8(len & 0xFF),
    ]
    let okHeader = header.withUnsafeBufferPointer { writeAll(fd: fd, bytes: $0.baseAddress!, count: 4) }
    guard okHeader else { return false }
    return payload.withUnsafeBytes { raw -> Bool in
        guard let base = raw.baseAddress else { return false }
        return writeAll(fd: fd, bytes: base.assumingMemoryBound(to: UInt8.self), count: payload.count)
    }
}

// Send length-prefixed JSON
guard writeFramed(fd: fd, payload: messageData) else {
    close(fd)
    exit(1)
}

close(fd)
exit(0)
