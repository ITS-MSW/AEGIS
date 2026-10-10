# AEGIS Architecture & System Specification

Aegis is a native macOS application for monitoring and interacting with AI coding agents (OpenAI Codex, Nous Hermes, OpenCode, and Google AntiGravity). It combines a borderless notch UI, a local Unix domain socket bridge, passive filesystem/database watchers, and audio synthesis.

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
- **Framing**: Newline-delimited JSON (`\n`)
- **Directionality**: Bidirectional (events flow agent $\to$ app; decisions flow app $\to$ agent)

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
  "activity_summary": "Running command",
  "terminal_info": {
    "app_bundle_id": "com.github.wez.wezterm",
    "term_session_id": "...",
    "iterm_session_id": null,
    "tmux_pane": "%1"
  }
}
```

### The 12 Canonical Lifecycle Events
`SessionStore` enforces a strict canonical event set. Non-canonical events are rejected to prevent socket pollution:

| Canonical Event | Trigger & Meaning |
| :--- | :--- |
| `SessionStart` | New agent session initiated; allocates or resumes session entry. |
| `SessionEnd` | Agent session officially terminated; triggers turn end and schedules removal. |
| `UserPromptSubmit` | User submitted a prompt; moves status to `.thinking` and engages power assertion. |
| `PreToolUse` | Agent is about to invoke a tool; moves status to `.toolUse` (or prompts approval in strict mode). |
| `PostToolUse` | Tool execution finished; records elapsed duration and tool outcome. |
| `PermissionRequest` | Agent requires explicit user consent; displays in-notch approval UI. |
| `Stop` | LLM turn finished; moves status to `.idle` and presents markdown finish card. |
| `Notification` | Informational notification from agent. |
| `SubagentStart` | Subagent spawned; increments active subagent execution count. |
| `SubagentStop` | Subagent completed; decrements active subagent execution count. |
| `PreCompact` | Context compaction initiated. |
| `ActivityUpdate` | Progress/status text update during long-running tool execution. |

### Strict Approval & Blocking Permission Handshake
When an agent asks for permission (or under strict approval mode):
1. `AegisBridge` sends `PermissionRequest` to `/tmp/aegis.sock`.
2. The bridge process blocks on the socket connection waiting for a response line.
3. Aegis displays the permission card in the notch.
4. The user clicks **Deny**, **Allow Once**, **Allow All**, or **Bypass**.
5. Aegis writes a `BridgeResponse` JSON payload back to the socket:
   ```json
   { "action": "allowOnce", "updatedPermissions": null }
   ```
6. `AegisBridge` parses the response and prints the provider's native approval payload to `stdout`, exiting with code 0 (or 1 for deny).

---

## 3. Provider Integration & Normalization

Each AI provider uses distinct hook mechanisms that Aegis normalizes:

### 1. OpenAI Codex
- **Integration**: Configured in `~/.codex/hooks.json` with `[features].hooks = true` in `~/.codex/config.toml`.
- **Permissions**: Supports `deny`, `allowOnce`, `allowAll`, and `bypass`.
- **Permission Persistence**: Codex requires prefix rules rather than runtime permission updates. Aegis appends `prefix_rule(...)` to `~/.codex/rules/aegis.rules`.
- **Questions**: Mirrored from `request_user_input` tool events; answers are deferred to Codex.

### 2. Nous Hermes
- **Integration**: Hooks merged into `~/.hermes/config.yaml`.
- **Sanitization**: Hermes CLI frequently outputs unescaped control characters (`\n`, `\t`) inside JSON strings; `AegisBridge` applies a byte-level sanitizer (`sanitizeControlChars`) before JSON parsing.
- **Strict Mode**: Translates `pre_tool_call` into a blocking `PermissionRequest` if enabled in `~/.aegis/config.json`.
- **Dictation Transcription**: Integrates directly with Hermes speech module (`tools.voice_mode.transcribe_recording`).

### 3. OpenCode
- **Integration**: Node.js plugin written to `~/.config/opencode/plugins/aegis.js` and registered in `opencode.json`.
- **Communication**: Communicates with OpenCode's local REST/IPC API.
- **Decisions**: Supports inline question answering and permissions (`deny`, `allowOnce`, `allowAll`).

### 4. Google AntiGravity (`agy`)
- **Integration**: Hooks group written to `~/.gemini/config/hooks.json` when `~/.gemini/antigravity` is present.
- **Enrichment**: AntiGravity emits compact hook payloads; `AegisBridge` reads `transcript.jsonl` from the active session directory to extract the latest user prompt, assistant response, and model.
- **Strict Approval**: Translates pre-tool hooks to blocking permission prompts.

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
  - `level = .statusBar + 1` (floats above menu bar and full-screen windows)
  - `isOpaque = false`, `backgroundColor = .clear`
  - `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`
- **View Hierarchy**:
  ```text
  NotchPanel (NSPanel)
    └── contentContainer (NSView - isolates constraint passes)
          └── ClickThroughHostingView (NSHostingView)
                └── NotchContentView (SwiftUI)
                      ├── NotchBackground (Shape & stroke border)
                      ├── CollapsedNotchView / SessionListView
                      ├── PermissionView / QuestionView
                      └── FinishedView
  ```

### Screen Detector (`ScreenDetector`)
- Uses `NSScreen.safeAreaInsets.top` to detect the presence and exact height of the physical MacBook notch.
- Calculates physical notch width from `screen.auxiliaryTopLeftArea` and `screen.auxiliaryTopRightArea`.
- Automatically centers panels on display parameter changes (`didChangeScreenParametersNotification`).

---

## 7. Terminal Jumper Engine

When a session card or finish notification is clicked, `TerminalJumper` activates the originating window:

```text
Session.terminalInfo
  ├── App Bundle ID
  ├── Terminal / iTerm / Kitty / Ghostty / WezTerm IDs
  ├── TMUX Pane ID
  └── Working Directory (CWD)
         │
         ▼
TerminalJumper Router
  ├── Codex Desktop     ──▶ Open URL `codex://threads/<id>`
  ├── Hermes Desktop    ──▶ AppleScript AXPress on session tab
  ├── iTerm2            ──▶ AppleScript session select by ID
  ├── Apple Terminal    ──▶ AppleScript tab select by CWD / TTY
  ├── Ghostty / WezTerm ──▶ Frontmost activation + working dir match
  ├── JetBrains IDEs    ──▶ Bundle ID activation + project directory
  └── VS Code / Cursor  ──▶ Bundle ID activation + workspace match
```

---

## 8. Power Management Subsystem

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

## 9. Audio Synthesis & Sound Engine

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

## 10. Rate Limiting & Runway Estimator

- **Polling**: Polls `https://chatgpt.com/backend-api/wham/usage` every 60 seconds using the access token in `~/.codex/auth.json`.
- **Classification**: Dynamically sorts returned quota windows by duration ($<2$ days = short 5h window, $\ge 2$ days = 7d weekly window).
- **Runway Estimator (`QuotaRunwayEstimator`)**:
  $$\text{Velocity} = \alpha \cdot \left(\frac{\Delta \text{Used}}{\Delta t}\right) + (1 - \alpha) \cdot \text{PreviousVelocity}$$
  Projected consumption is compared against remaining quota:
  - $\text{Ratio} \le 0.70 \implies \text{Comfortable (Green)}$
  - $0.70 < \text{Ratio} \le 1.00 \implies \text{Watch (Orange)}$
  - $\text{Ratio} > 1.00 \implies \text{Tight (Red)}$

---

## 11. On-Disk State Layout

Aegis stores all operational state under `~/.aegis/`:

```text
~/.aegis/
├── bin/
│   ├── aegis-codex-bridge
│   ├── aegis-hermes-bridge
│   ├── aegis-opencode-bridge
│   └── aegis-antigravity-bridge
├── cache/
│   └── rl.json                  # Rate limit cache
├── run/
│   └── aegis.pid                # Process lock PID file
├── sound-packs/                 # Custom user sound files
│   └── *.wav / *.aiff / *.mp3
├── config.json                  # Strict approval configuration
└── debug.log                    # Diagnostic log stream
```
