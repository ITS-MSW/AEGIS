# Aegis Engineering Guide

Aegis is a native macOS notch app for monitoring four AI coding agents: Codex, Hermes, OpenCode, and AntiGravity. It is written in Swift 6.2 with Swift 5 language mode with SwiftUI and AppKit, targets macOS 14+, and builds with Swift Package Manager.

## Architecture

```text
agent hook
  -> ~/.aegis/bin/aegis-<agent>-bridge
  -> AegisBridge --source <agent>
  -> /tmp/aegis.sock
  -> SocketServer
  -> SessionStore
  -> NotchWindowController / SwiftUI views
```

The app target is `Aegis`. The bridge target is `AegisBridge`. On launch, `CodexInstaller` and the descriptor-driven `ProviderInstaller` write provider launchers under `~/.aegis/bin` and merge managed hook entries into detected configurations. Each launcher resolves the bridge embedded in the current app bundle before trying installed-app and development paths.

Do not launch the app in an environment where provider configs must remain untouched. First launch may install hooks.

## Build and app bundle

```bash
swift build
swift build -c release
./scripts/build-app.sh
open build/Aegis.app
```

`scripts/build-app.sh` compiles the release products and assembles a runnable app bundle at `build/Aegis.app`.

## Provider source of truth

`AIProvider.all` contains exactly:

- `codex`
- `hermes`
- `opencode`
- `antigravity`

Each provider owns a display name, accent color, mascot palette, and mascot shape. CLI icons live in `Resources/cli-icons/<id>.png`; rendered documentation mascots live in `docs/mascots/<id>.png`.

## Bridge protocol

Each hook invokes `AegisBridge`, which reads JSON from stdin, stamps the provider source, captures its parent PID, normalizes the event, and sends one four-byte big-endian length-prefixed JSON message over the Unix socket, then exits without waiting for a reply or printing a decision.

The canonical events are:

- `SessionStart`
- `SessionEnd`
- `UserPromptSubmit`
- `PreToolUse`
- `PostToolUse`
- `PermissionRequest`
- `Stop`
- `Notification`
- `SubagentStart`
- `SubagentStop`
- `PreCompact`
- `ActivityUpdate`

`SessionStore` rejects non-canonical events. Preserve this guard: a foreign hook sharing the socket must not create or mutate a session.

Important bridge fields include `session_id`, `hook_event`, `source`, `cwd`, `tool_name`, `tool_input`, `user_message`, `assistant_message`, `agent_pid`, `parent_session_id`, `is_ephemeral`, and `activity_summary`.

## Provider normalization

### Codex

Codex uses native `hooks.json` events plus `[features].hooks = true` in `~/.codex/config.toml`. The installer merges managed commands without replacing foreign hooks.

Codex permissions and `request_user_input` remain provider-owned. The bridge reports waiting status without returning approval decisions or modifying existing rules.

The passive Codex Desktop watcher enriches sessions with thread names and lifecycle events. The process sweep remains the fallback for sessions whose hook stream omits a terminal event.

### Hermes

Hermes hooks are merged into `~/.hermes/config.yaml`. Preserve existing YAML content and foreign hooks. Hermes event names are normalized into the canonical set.

The bridge sanitizes raw control characters inside JSON strings and normalizes Hermes lifecycle events. `clarify` marks the session waiting; questions are answered in Hermes. Pre-tool hooks are observational.

### OpenCode

The installer writes the Aegis plugin under `~/.config/opencode/plugins/` and registers it in `~/.config/opencode/opencode.json` without discarding unrelated plugins.

The plugin translates OpenCode lifecycle events, `permission.asked`, and question events into canonical bridge messages. It never calls approval or question-answer APIs. Keep observations nonblocking so OpenCode retains its native prompts and approval policy.

### AntiGravity

The installer merges a named `aegis` hook group into `~/.gemini/config/hooks.json`. It only installs when AntiGravity is detected under `~/.gemini/antigravity`. AntiGravity must be restarted after hook changes because its daemon caches configuration.

AntiGravity emits limited hook payloads. The bridge reads its `transcript.jsonl` to recover the latest user request and model planner response. Its tool hooks remain observational and leave native approvals unchanged.

## Installer guarantees

Managed entries contain the marker `# aegis-managed` or the equivalent structured `aegis` key. Installer changes must be additive:

- Preserve foreign hooks and unrelated configuration.
- Create a backup before rewriting an existing config.
- Use atomic replacement where implemented.
- Keep launcher names under `~/.aegis/bin`.
- Keep socket and config paths centralized; do not introduce legacy path fallbacks.

The retained installer formats are `hermesYAML`, `opencodePlugin`, and `antigravityJSON`, plus the dedicated Codex installer.

## Session lifecycle

`SessionStore` is the session source of truth. It maintains active state, current tool, execution/waiting status, last user/assistant text, model, and provider identity.

The process sweep runs every five seconds. It validates the captured PID and process start time before marking a vanished agent complete, preventing false matches after PID reuse. Session persistence and recovery must remain provider-neutral.

Waiting permissions and questions are passive status signals. Resume execution tracking only when the provider reports progress; completion and process sweeping still end execution leases.

## Compact notch

`NotchWindowController` owns a single compact size per display configuration and visibility based on active sessions. Its borderless AppKit panel ignores mouse events and cannot become key. The SwiftUI content shows only the latest active provider mascot, aggregate status, and count.

Preserve screen adaptation, provider mascot palettes, compact typography, sound synthesis, and keep-awake safeguards. Permissions and questions stay in the originating provider. The menu bar offers app controls without a session list. Dictation remains in its independent bottom capsule.

## Logging and state

Runtime state is under `~/.aegis`:

- `debug.log`
- `sound-packs/`
- `bin/`

The app bundle identifier and UserDefaults domain are `dev.aegis.app`. The sole socket path is `/tmp/aegis.sock`.

## Change discipline

Keep diffs limited to the requested behavior. Do not replace the bridge, installer, session, theme, mascot, sound, or power engines with new abstractions. After changes, run `swift build`; for release-affecting changes also run `swift build -c release` and `./scripts/build-app.sh`.
