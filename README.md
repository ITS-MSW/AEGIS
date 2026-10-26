# Aegis

Aegis is a personal macOS notch app for monitoring AI coding agents. It receives agent hook events through a small bridge and shows aggregate agent status in a compact, passive notch panel.

Codex Desktop and Hermes Desktop are monitored directly from their local session stores. Their desktop integrations do not require launching either provider from a terminal.

Supported agents:

- Codex
- Hermes
- OpenCode
- AntiGravity (`agy`)

Dictation uses Parakeet TDT v3 through FluidAudio. Aegis imports the existing BetterWispr model when available, or you can choose its folder in Settings > Transcription. No model download is required. Recordings are temporary; Insights stores counts, not transcripts.

## Requirements

- macOS 14 or later
- Swift 6.2 or later
- At least one supported agent installed and configured

## Build

```bash
swift build
swift build -c release
```

Build a runnable macOS app bundle:

```bash
./scripts/build-app.sh 0.1.0
```

The app is written to `build/Aegis.app`.

For updates that retain macOS permissions, use the same code-signing identity on every build:

```bash
AEGIS_SIGNING_IDENTITY="Your code-signing identity" ./scripts/build-app.sh 0.1.0
```

Without this variable, the build is ad-hoc signed. Its identity changes when the executable changes, so an enabled Accessibility or Input Monitoring entry can belong to an older build. Remove Aegis from the affected list in System Settings, add the installed app again, and enable it. Switching signing identities also requires granting access again.

## Run

Run the SwiftPM debug executable:

```bash
.build/debug/Aegis
```

Or launch the app bundle:

```bash
open build/Aegis.app
```

> First launch installs Aegis hook entries into detected agent configurations under `~/.codex`, `~/.hermes`, `~/.gemini`, and `~/.config/opencode`. Back up those files first if you need an external recovery point.

## Architecture

```text
Agent hooks
    -> ~/.aegis/bin/aegis-<agent>-bridge
    -> AegisBridge
    -> /tmp/aegis.sock
    -> session store
    -> SwiftUI/AppKit notch window

Codex Desktop ~/.codex/sessions/*.jsonl ─┐
Hermes Desktop ~/.hermes/state.db ───────┴─> canonical events -> session store
```

The bridge normalizes provider events into the app's canonical event set. Session/process sweeping, desktop watchers, sound cues, agent keep-awake, and mascot rendering continue in the background.

The notch stays compact: it shows the latest active provider mascot, status dot, and active-session count, and hides when no sessions are active. Mouse movement and clicks do not open it. Permissions and questions are answered in the originating provider; Aegis only observes waiting status and never returns decisions or changes approval rules. The menu bar retains sound, settings, hook installation, Welcome, What's New, and Quit actions.

Runtime state is stored under `~/.aegis/`:

```text
~/.aegis/
├── bin/
├── debug.log
├── run/aegis.pid
└── sound-packs/
```

Useful development commands:

```bash
tail -f ~/.aegis/debug.log
echo '{"session_id":"test","hook_event_name":"SessionStart","cwd":"/tmp"}' \
  | .build/debug/AegisBridge --source codex
```

This repository is personal and private. It is not distributed as an open-source project.

## Potential future features

- Background dictation insertion into compatible apps, with verified delivery to the original field without activating its window. Keep return-and-paste as the compatibility fallback; do not assume every editor supports background accessibility writes.
