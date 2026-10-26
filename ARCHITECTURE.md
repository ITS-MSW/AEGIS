# AEGIS Architecture & System Specification

Aegis is a native macOS application for monitoring AI coding agents (OpenAI Codex, Nous Hermes, OpenCode, and Google AntiGravity). It combines a borderless notch UI, a local Unix domain socket bridge, passive filesystem/database watchers, and audio synthesis.

---

## 1. High-Level Architecture

```text
┌────────────────────────────────────────────────────────────────────────┐
│                          AI Coding Agents                              │
│                                                                        │
│   Codex CLI       Hermes CLI       OpenCode CLI     AntiGravity (agy)  │
│   (hooks.json)   (config.yaml)     (plugin.js)        (hooks.json)     │
└────────┬──────────────┬─────────────────┬───────────────────┬──────────┘
         │              │                 │                   │
         └──────────────┴────────┬────────┴───────────────────┘
                                 ▼
                     ~/.aegis/bin/aegis-<agent>-bridge
                                 ▼
                    AegisBridge CLI Executable
                                 ▼ (Unix Domain Socket /tmp/aegis.sock)
┌────────────────────────────────────────────────────────────────────────┐
│                        Aegis macOS Application                         │
│                                                                        │
│   SocketServer ──▶ SessionStore ──▶ NotchWindowController / SwiftUI   │
│                         ▲                     ▲                        │
│                         │                     │                        │
│   CodexDesktopWatcher ──┤                                              │
│   (~/.codex/sessions)   │                     ▲                        │
│                         │                     │                        │
│   HermesDesktopWatcher ─┘             SoundEngine & Synthesizer        │
│   (~/.hermes/state.db)                        ▲                        │
│                                               │                        │
│                             AgentExecutionPowerController (IOKit)      │
└────────────────────────────────────────────────────────────────────────┘
```

The system operates across two main boundaries:
1. **Agent Integration Boundary**: Lightweight wrapper launchers in `~/.aegis/bin/` invoke `AegisBridge`, which captures runtime context, normalizes event structures, and sends JSON over `/tmp/aegis.sock`.
2. **Application Boundary**: The main `Aegis` Cocoa app receives socket events, runs independent passive desktop watchers, maintains in-memory session states, and renders non-activating AppKit overlays.

---

## 2. IPC Protocol & Bridge Architecture

### Socket Specification
- **Path**: `/tmp/aegis.sock`
- **Transport**: Unix Domain Stream Socket (`AF_UNIX`, `SOCK_STREAM`)
- **Framing**: Four-byte big-endian length prefix followed by JSON (maximum 4 MB)
- **Directionality**: One-way events from agent to app; the server closes each connection after reading the event

### Bridge Message Schema (`BridgeMessage`)
```json
{
  "session_id": "8f0312aa-...",
  "hook_event": "PreToolUse",
  "source": "codex",
  "cwd": "/Users/user/dev/project",
  "tool_name": "bash",
  "tool_input": "git status",
  "user_message": "Check git status",
  "assistant_message": null,
  "agent_pid": 14209,
  "parent_session_id": null,
  "is_ephemeral": false,
  "effort_level": "medium",
  "model": "gpt-5",
  "activity_summary": "Running command"
}
```

### The 12 Canonical Lifecycle Events
`SessionStore` enforces a strict canonical event set. Non-canonical events are rejected to prevent socket pollution:

| Canonical Event | Trigger & Meaning |
| :--- | :--- |
| `SessionStart` | New agent session initiated; allocates or resumes session entry. |
| `SessionEnd` | Agent session officially terminated; triggers turn end and schedules removal. |
| `UserPromptSubmit` | User submitted a prompt; moves status to `.thinking` and engages power assertion. |
| `PreToolUse` | Agent is about to invoke a tool; moves status to `.toolUse`; native question tools instead mark the session waiting. |
| `PostToolUse` | Tool execution finished; records elapsed duration and tool outcome. |
| `PermissionRequest` | Native provider requests input; marks the session waiting without answering it. |
| `Stop` | LLM turn finished; moves status to `.idle` and removes the session from the compact active count. |
| `Notification` | Informational notification from agent. |
| `SubagentStart` | Subagent spawned; increments active subagent execution count. |
| `SubagentStop` | Subagent completed; decrements active subagent execution count. |
| `PreCompact` | Context compaction initiated. |
| `ActivityUpdate` | Progress/status text update during long-running tool execution. |

### Native Permission and Question Handling

The bridge sends observations and exits without reading replies or writing decisions to stdout. `SessionStore` uses waiting status to update the compact indicator and release keep-awake assertions. Native progress events resume execution tracking. There is no approval queue, answer storage, or automatic decision in Aegis.

---

## 3. Provider Integration & Normalization

Each AI provider uses distinct hook mechanisms that Aegis normalizes:

### 1. OpenAI Codex
- **Integration**: Configured in `~/.codex/hooks.json` with `[features].hooks = true` in `~/.codex/config.toml`.
- **Permissions and questions**: Observed without answering. `request_user_input` pauses execution tracking until Codex reports progress. Existing provider approval rules are left untouched.

### 2. Nous Hermes
- **Integration**: Hooks merged into `~/.hermes/config.yaml`.
- **Sanitization**: Hermes CLI frequently outputs unescaped control characters (`\n`, `\t`) inside JSON strings; `AegisBridge` applies a byte-level sanitizer (`sanitizeControlChars`) before JSON parsing.
- **Tool hooks**: Normalize lifecycle events without reading a strict-approval configuration or pausing for Aegis UI.
- **Dictation**: Independent of Hermes. `DictationTranscriptionRunner` retains FluidAudio's Parakeet TDT v3 engine; `DictationCapsule` presents a nonactivating bottom panel. Output uses the live focused field or the clipboard, without restoring focus. Vocabulary and daily usage counts live in Aegis Application Support; audio is temporary.

### 3. OpenCode
- **Integration**: Node.js plugin written to `~/.config/opencode/plugins/aegis.js` and registered in `opencode.json`.
- **Communication**: Sends lifecycle and waiting-status observations through the bridge. It never calls OpenCode's approval or question-answer APIs.

### 4. Google AntiGravity (`agy`)
- **Integration**: Hooks group written to `~/.gemini/config/hooks.json` when `~/.gemini/antigravity` is present.
- **Enrichment**: AntiGravity emits compact hook payloads; `AegisBridge` reads `transcript.jsonl` from the active session directory to extract the latest user prompt, assistant response, and model.
- **Tool hooks**: Remain observations; native provider approval handling is unchanged.

---

## 4. Passive Desktop Session Watchers

To monitor desktop GUI applications without running resource-heavy CLI daemons, Aegis uses passive filesystem and database monitors:

```text
Codex Desktop Log Stream:
~/.codex/sessions/*.jsonl ──▶ ReverseJSONLReader ──▶ Canonical BridgeMessage ──▶ SessionStore
~/.codex/state_5.sqlite   ──▶ SQLite Title Query ──┘

Hermes Desktop State:
~/.hermes/state.db        ──▶ SQLite WAL Query    ──▶ Canonical BridgeMessage ──▶ SessionStore
~/.hermes/state.db-wal    ──▶ FileEventMonitor    ──┘
```

### Codex Desktop Session Watcher
- Monitors `~/.codex/sessions/*.jsonl` for file append events.
- Uses `ReverseJSONLReader` to scan backwards from file EOF, avoiding reading megabytes of history into memory.
- Reads thread titles and metadata on demand from `~/.codex/state_5.sqlite` using `SQLITE_OPEN_READONLY` with busy timeouts.

### Hermes Desktop Session Watcher
- Observes `~/.hermes/state.db` and SQLite WAL files (`state.db-wal`, `state.db-shm`).
- Employs `FileEventMonitor` (GCD dispatch sources on file descriptors) combined with a debounced reconciliation scheduler (`HermesReconciliationPolicy`).
- Extracts session state directly from SQLite message rows.

---

## 5. Session Lifecycle & Process Sweeping

Because AI agents can crash, be killed with `SIGKILL`, or exit without firing `SessionEnd`, Aegis maintains an active process sweep:

1. **Sweep Interval**: Runs every 5 seconds via `Timer`.
2. **PID Liveness Check**: Calls `kill(pid, 0)`.
3. **PID Recycling Defense**:
   - macOS kernels recycle PIDs rapidly. Simply checking `kill(pid, 0) != -1` can produce false positives if an unrelated process gets the same PID.
   - Aegis queries `sysctl` with `[CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]` to capture `kp_proc.p_starttime` (seconds and microseconds) at session start.
   - If the current process start time differs from the recorded start time, the original agent is dead.
4. **Provider-Specific Inactivity Fallbacks**:
   - **Codex CLI**: Routes through a persistent `app-server` daemon, so parent PID checks are ineffective. Sessions idle for $> 5$ minutes are cleaned up.
   - **Hook-Only Background Sessions**: Expire after 15 minutes of inactivity.
   - **Abandoned Active Work**: Unfinished sessions with no events for 24 hours are dropped.

---

## 6. UI Architecture & Screen Adaptation

### AppKit Notch Panel (`NotchPanel`)
- **Subclass**: Custom `NSPanel` configured with:
  - `styleMask: [.borderless, .nonactivatingPanel]`
  - `level = 27` (floats above menu bar and full-screen windows)
  - `isOpaque = false`, `backgroundColor = .clear`
  - `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`
- **View Hierarchy**:
  ```text
  NotchPanel (NSPanel)
    └── contentContainer (NSView - isolates constraint passes)
          └── NSHostingView
                └── NotchContentView (SwiftUI)
                      └── CollapsedNotchView (mascot, status, count)
  ```

The panel ignores mouse events, cannot become key, and has only one size per display configuration. `NotchWindowController` updates its frame on display changes and shows it only while active sessions exist. There are no expansion states, timers, content measurements, or resize animations. Theme choices retain compact typography and the existing Codex mascot mask; previews use the compact layout.

### Screen Detector (`ScreenDetector`)
- Uses `NSScreen.safeAreaInsets.top` to detect the presence and exact height of the physical MacBook notch.
- Calculates physical notch width from `screen.auxiliaryTopLeftArea` and `screen.auxiliaryTopRightArea`.
- Automatically centers panels on display parameter changes (`didChangeScreenParametersNotification`).

---

## 7. Power Management Subsystem

To keep AI coding agents executing when the user steps away:
- **Assertion**: Acquires IOKit power assertion `kIOPMAssertPreventUserIdleSystemSleep` with description `"Aegis agent execution"`.
- **Modes**:
  - `Off`: Normal macOS sleep behavior.
  - `On Power Adapter`: Assertions acquired only on AC power.
  - `On Power Adapter and Battery`: Keeps working on battery with strict safeguards.
- **Safeguards**:
  - Inactivity lease: Automatically releases battery assertion after 2 hours without agent progress.
  - Thermal / Battery monitor: Automatically releases assertion if macOS enters Low Power Mode or signals a low-battery warning.
  - Display policy: Does **not** prevent display sleep; only idle system sleep is inhibited.

---

## 8. Audio Synthesis & Sound Engine

- **Synthesis**: `SoundSynthesizer` generates pure audio mathematically using multi-partial sine wave oscillators, ADSR envelopes, and exponential decay curves.
- **Lazy Engine Lifecycle**:
  - `AVAudioEngine` and `AVAudioPlayerNode` are allocated on-demand.
  - After any playback completes, a 2-second idle timer starts.
  - If no further sound plays within 2 seconds, the audio engine is stopped and detached, reducing idle memory and zeroing CPU consumption.
- **Custom Sound Packs**:
  - Reads audio files from `~/.aegis/sound-packs/`.
  - Converts incoming audio formats (.wav, .mp3, .m4a, .aiff, .caf) to the engine's internal format (44.1kHz mono PCM) via `AVAudioConverter`.
- **Events**: Only session end and error trigger sounds. Other lifecycle events remain available to session monitoring without playing audio.

---

## 9. On-Disk State Layout

Aegis stores all operational state under `~/.aegis/`:

```text
~/.aegis/
├── bin/
│   ├── aegis-codex-bridge
│   ├── aegis-hermes-bridge
│   ├── aegis-opencode-bridge
│   └── aegis-antigravity-bridge
├── run/
│   └── aegis.pid                # Process lock PID file
├── sound-packs/                 # Custom user sound files
│   └── *.wav / *.aiff / *.mp3
└── debug.log                    # Diagnostic log stream
```
