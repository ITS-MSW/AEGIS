# AEGIS Features

Comprehensive list and technical summary of all features, capabilities, subsystems, and integrations in AEGIS.

---

## Notch Window & UI Shell

What : [ Top-Center Borderless Notch Window ]
How : Borderless AppKit panel (`NSPanel`, `.borderless`, `.nonactivatingPanel`) hosting SwiftUI that centers itself seamlessly over the physical MacBook display notch (`safeAreaInsets.top`) or renders as a clean top-centered bar on non-notch Macs and external monitors (`ScreenDetector.notchPanelFrame`). Responds dynamically to display connection and reconfiguration events (`didChangeScreenParametersNotification`).
Notes : Does not steal focus from active applications; automatically remains hidden when no agent sessions or pending actions require attention.
----
What : [ Adaptive Notch Hover & Click Expansion ]
How : Expands instantly on mouse hover on the built-in standalone display. On multi-display setups, applies a 350ms intent delay before opening so rapid cursor crossings between screens do not trigger accidental expansions. Clicking the collapsed bar opens the notch immediately regardless of display count. Can be switched to click-only mode via Settings.
Notes : Configurable in Settings > General (`expandOnHover`).
----
What : [ Collapsed Notch Pill & Live Aggregate Status ]
How : Renders a compact top-edge pill showing the active provider's pixel-art mascot on the left and a colored status dot with active session count on the right. Status color dynamically reflects aggregate state across all sessions: cyan for active thinking/tool execution, orange for pending permissions/questions, green for idle/completed turns, and gray for inactive.
Notes : Always mirrors the most recently active session when multiple agents are running in parallel.
----
What : [ Expanded Session Cards & Interactive Session List ]
How : Expands into a 600pt wide panel displaying active sessions grouped by agent provider. Each card displays provider icon and mascot, project folder name or thread title, status pill, active model name, elapsed duration, and last message. Hovering over a session card triggers a spring-animated card morph that reveals an inline markdown preview of the turn. Clicking a card jumps directly to the originating terminal or app.
Notes : Includes provider filter chips (ALL vs specific provider) and collapsible provider section headers when sessions span multiple providers.
----
What : [ Live Agent Activity & Dynamic Subtitle ]
How : Normalizes low-level tool calls and hook events (`PreToolUse`, `ActivityUpdate`) into human-readable action summaries (e.g., "Editing files" for `apply_patch`, "Running command" for shell execution, "Browsing the web", "Generating image", "Starting subagent", "Waiting for result").
Notes : Displayed in real time on session cards and collapsed previews.
----
What : [ Auto-Expanded Markdown Finish Card ]
How : When an agent turn finishes, automatically pops open a rich notification card rendering the full assistant response formatted in markdown, completion duration badge (e.g., "Finished in 2m"), effort level indicator, and a direct button to jump into the session. Users can collapse it to a glanceable 2-line card or let it auto-collapse after 5 seconds.
Notes : Auto-collapse timer automatically pauses while mouse cursor hovers over the card (up to a 30-second ceiling).
----

## Agent Permissions & Interactive Decisions

What : [ In-Notch Interactive Permission Review Queue ]
How : Intercepts blocking agent permission requests and displays a dedicated approval view in the notch. Shows the tool name, tool category icon and color pill, target file path or command pattern, and an expandable syntax-highlighted code diff or command box. Provides provider-aware action buttons: Deny, Allow Once, Allow All, and Bypass.
Notes : Multiple pending permissions are queued FIFO (oldest first) so responding to one smoothly advances to the next without jumping or racing button clicks. Can auto-expand the notch via Settings > General (`autoExpandOnPermission`).
----
What : [ Codex Persistent Permission Rules (aegis.rules) ]
How : When "Allow All" or "Bypass" is chosen on a Codex bash permission request, parses and sanitizes the shell command tokens and appends a persistent `prefix_rule(...)` to `~/.codex/rules/aegis.rules`. Codex consults this file on future commands to auto-approve matching execution without prompting again.
Notes : Applies to shell/bash commands; non-bash tools fall back to Allow Once because Codex prefix rules match command tokens rather than tool names.
----
What : [ In-Notch Interactive Question & Clarification Mirroring ]
How : Surfaces interactive questions asked by agents (e.g., multiple choice, plan selection, clarification requests) directly in the notch with single-select options, multi-select checkboxes, and custom write-in input fields.
Notes : For agents supporting inline answers (OpenCode, AntiGravity), answers are submitted directly from the notch. For agents requiring terminal answers (Codex, Hermes), mirrors the question and provides an instant button to jump to the originating terminal or app.
----
What : [ Strict Action Approval ("Review Every Action") ]
How : For agents that expose blanket pre-tool hooks rather than native selective permission prompts (Hermes and AntiGravity), converts every tool execution into a blocking in-notch Allow/Deny prompt before execution proceeds.
Notes : Opt-in per provider in Settings > General (`strictApproval`); mirrored to `~/.aegis/config.json` so the bridge process can read it independently without attaching to the main app. Unanswered requests time out safely after ~5 minutes.
----

## Terminal & Desktop Deep Linking

What : [ Terminal & IDE Deep-Link Jumper ]
How : Captures terminal environment variables (`ITERM_SESSION_ID`, `TERM_SESSION_ID`, `TMUX_PANE`, `KITTY_WINDOW_ID`, `WEZTERM_UNIX_SOCKET`, frontmost app bundle ID, and working directory) and uses dedicated AppleScript and workspace adapters to focus the originating tab, window, or pane when a session card or notification is clicked.
Notes : Supports Apple Terminal, iTerm2, Ghostty, Kitty, WezTerm, tmux, VS Code, Cursor, Windsurf, and JetBrains IDEs (IntelliJ IDEA, WebStorm, PyCharm, GoLand).
----
What : [ Codex Desktop Deep Link Jump ]
How : Session cards for Codex Desktop open the exact thread directly inside Codex Desktop via custom URL scheme `codex://threads/<threadId>`.
Notes : Does not require terminal execution or window searching; jumps directly to the thread UI.
----
What : [ Hermes Desktop Tab-Focusing Jump ]
How : Session cards for Hermes Desktop bring the Hermes app to the foreground and use macOS Accessibility (`System Events`) to identify and select the exact matching session tab based on the session title or initial prompt.
Notes : Prompts for macOS Accessibility permission on first use. Falls back gracefully to activating the Hermes application window if accessibility permission is not granted.
----

## Supported Agents & Integrations

What : [ Supported Agent: OpenAI Codex ]
How : Monitored via CLI hooks in `~/.codex/hooks.json` (enabled via `[features].hooks = true` in `~/.codex/config.toml`) and passive desktop log watching in `~/.codex/sessions/*.jsonl`. Supports CLI permission handling (Deny, Allow Once, Allow All, Bypass), question mirroring, and thread deep-linking.
Notes : Installer merges managed hooks without modifying existing foreign hooks. Backs up original config before modification.
----
What : [ Supported Agent: Nous Hermes ]
How : Monitored via CLI hooks merged into `~/.hermes/config.yaml` and desktop SQLite database watching in `~/.hermes/state.db`. Bridge sanitizes unescaped control characters in JSON streams, normalizes LLM call events, tool execution, and consent requests into canonical events.
Notes : Supports push-to-talk voice handoff and opt-in strict tool approval.
----
What : [ Supported Agent: OpenCode ]
How : Monitored via an Aegis plugin installed to `~/.config/opencode/plugins/aegis.js` and registered in `~/.config/opencode/opencode.json`. Plugin translates lifecycle, permissions, and question events to the bridge socket, and applies user decisions through OpenCode's local API.
Notes : Fully supports inline question answering and permissions (Deny, Allow Once, Allow All).
----
What : [ Supported Agent: Google AntiGravity (agy) ]
How : Monitored via named `aegis` hook group merged into `~/.gemini/config/hooks.json` when `~/.gemini/antigravity` is detected. Bridge inspects `transcript.jsonl` to enrich events with user prompt, assistant response, and model details.
Notes : Supports inline question answering and strict approval mode. AntiGravity daemon must be restarted after hook installation to reload configs.
----
What : [ Desktop Session Watcher: Codex Desktop ]
How : Passively watches `~/.codex/sessions/*.jsonl` log files and queries `~/.codex/state_5.sqlite` using SQLite readonly mode and busy timeouts to detect active desktop sessions, thread titles, prompts, and tool states without launching extra background subprocesses.
Notes : Purely read-only monitoring; permission prompts remain within Codex Desktop.
----
What : [ Desktop Session Watcher: Hermes Desktop ]
How : Passively monitors `~/.hermes/state.db` using WAL-safe SQLite queries and filesystem event monitors (`FileEventMonitor`) to discover active desktop sessions, turns, tool calls, and completions in real time.
Notes : Purely read-only monitoring; desktop permissions remain handled inside Hermes Desktop.
----
What : [ Automatic Idempotent Hook Installers ]
How : Automatically inspects detected agent configurations on every launch and merges required Aegis hooks non-destructively, writing wrapper executables to `~/.aegis/bin/aegis-<source>-bridge`. Creates timestamped/named backups (`.bak-aegis`) prior to modifying configs.
Notes : Can be manually triggered anytime via Menu Bar > "Install Hooks" or Settings > Integrations ("Reinstall hooks").
----
What : [ Subagent Session Management ]
How : Tracks parent-child session relationships (`parentSessionId`, `SubagentStart`, `SubagentStop`). Subagent sessions are hidden from the main notch by default to avoid visual clutter, but automatically pop into view whenever user input or permission approval is required.
Notes : Toggleable in Settings > General (`Show subagents`) to display all child agent sessions as separate cards.
----

## Voice Dictation & Input Insertion

What : [ Voice Dictation (Caret Insertion) ]
How : Global speech dictation that records microphone input, transcribes it via the local Hermes speech engine, and inserts the transcription directly at the live caret position of the focused text field in any macOS application using macOS Accessibility (`AXUIElement`) and simulated Paste. Automatically restores clipboard contents after pasting.
Notes : Requires macOS Accessibility and Microphone permissions. Includes verification of insertion and caret position.
----
What : [ Dictation Shortcut Modes & Custom Triggers ]
How : Supports two distinct recording modes:
  1. Toggle mode: Double-press Shift to start recording, double-press Shift to finish, Escape to cancel.
  2. Hold mode (Push-to-Talk): Hold Shift to record, release to transcribe and insert.
Allows selecting whether to trigger on Either Shift, Left Shift, or Right Shift.
Notes : Configurable in Settings > Transcription. Uses low-level event taps (`CGEventTap`) for responsive detection without consuming regular typing keys.
----
What : [ Dictation System Audio Output Muting ]
How : Optional toggle that mutes system audio output while dictation recording is active and automatically un-mutes / restores original audio levels when recording ends.
Notes : Configurable in Settings > Transcription (`Mute while recording`). Prevents speaker output from contaminating microphone capture.
----
What : [ Dictation Microphone Selection & Monitoring ]
How : Dynamically monitors connected audio input devices via CoreAudio. Users can select "Automatic, prefer built-in microphone" or lock dictation to a specific USB/Bluetooth microphone. Automatically detects disconnections and falls back safely.
Notes : Configurable in Settings > Transcription. Shows live input device connection status.
----
What : [ Uninserted Transcript Buffer & Recovery ]
How : If direct insertion fails (e.g. focused window closed, field inaccessible, or text modified during speech), the transcribed text is copied to the clipboard and retained in an "Uninserted transcript" section in Settings > Transcription, where it can be reviewed, copied, or cleared.
Notes : Ensures spoken transcripts are never lost when third-party apps misbehave or lose focus.
----

## Hermes Voice Handoff

What : [ Hermes Push-to-Talk Voice Handoff ]
How : Hold `Control-Option-Space`, speak a task prompt, and release. Aegis captures the utterance, transcribes it using Hermes speech tools (`tools.voice_mode.transcribe_recording`), and submits the prompt to Hermes via `hermes chat --query <prompt> --in <working_dir> --source desktop`. Audio files are removed immediately after submission.
Notes : Renders an animated floating capsule overlay (`HermesVoiceCapsule`) near the notch showing live audio input waveforms and submission status. Prompts are passed via stdin for security.
----
What : [ Hermes Voice Target & Directory Selection ]
How : Allows configuring whether voice handoffs start a fresh Hermes conversation (`New session`) or continue the most recent conversation in that directory (`Latest in folder`, `--resume latest`). Includes a folder picker to choose the default working directory.
Notes : Configurable in Settings > Integrations > Hermes Voice.
----

## Ambient Desktop Companion (Mysa)

What : [ Mysa Ambient Desktop Companion ]
How : An optional transparent desktop sprite panel hosting "Mysa", an ambient pixel-art sentinel that visualizes agent activity states: idle, observing (sessions open), working (thinking or executing tools), attention (pending approval or question), success (transient celebration upon turn completion), and failure (errors).
Notes : No accounts, streaks, economies, or gamified loops. Animation pauses when occluded, hidden, idle, in Low Power Mode, or when Reduce Motion is enabled. Can be dragged anywhere on desktop; coordinates are persisted across launches.
----
What : [ Companion Scale Adjustment ]
How : Slider in Settings > Appearance allowing continuous scaling of the Mysa sprite from 75% to 150% size.
Notes : Re-scales the floating panel smoothly without blurring pixel art.
----
What : [ Companion Workspace Follow (Spaces) ]
How : Toggle (`companionFollowsActiveWorkspace`) that sets `NSWindow.collectionBehavior` to `.canJoinAllSpaces`, ensuring Mysa remains visible on your desktop as you navigate between macOS virtual desktops / Spaces.
Notes : Configurable in Settings > Appearance.
----

## Visual Themes & Customization

What : [ Custom Theme: Aegis (Default) ]
How : Near-black background surfaces (`#07050C`), restrained violet borders (`rgba(139, 92, 246, 0.72)`), subtle dark card wells, and clean native macOS typography.
Notes : Preserves semantic cyan, green, and orange status colors for meaningful data while maintaining a sleek dark aesthetic.
----
What : [ Custom Theme: Liquid Glass ]
How : Translucent frosted blur material (`.regularMaterial`) with subtle white highlights, pill-shaped controls, and a lightweight native macOS look.
Notes : Card backgrounds use blurred material glass effect.
----
What : [ Custom Theme: Retro Pixel ]
How : 8-bit aesthetic featuring chunky 2px borders, perfectly square corners (zero radius), hard offset tinted shadows matching surface hues, monospaced typography, and warm terracotta active card tints.
Notes : Pill corners and buttons are fully squared.
----
What : [ Custom Theme: Terminal ]
How : Pitch-black OLED surfaces, hairline 1px borders, near-invisible minimalist chrome, and high-density monospaced layout.
Notes : Maximizes information density with minimal visual decoration.
----
What : [ Custom Theme: Brutalist ]
How : High-contrast design featuring thick 2px solid black strokes, solid bright accent action buttons, and light cards with dark bold sans typography.
Notes : Wells and cards flip to light cream surfaces with dark text for high contrast.
----
What : [ Custom Theme: Web-Slinger ]
How : Midnight and suit-red color scheme, spider webbing dynamically drawn into panel top corners (`WebOverlay`), and an animated masked spider hanging on a thread (`WebSlingerSpider`). Codex mascot wears a spider mask overlay.
Notes : Features dynamic `SpiderLens` status readouts (wide when idle, squinted band when thinking, wide alarmed on permissions, and symbiote black on error).
----
What : [ Custom Theme: Default ]
How : Pure black background, monospaced typography, and soft rounded cards.
Notes : Retains original classic notch styling.
----
What : [ Provider-Specific Pixel Mascots ]
How : Custom pixel-art mascots rendered on Canvas for each supported agent: Codex (chunky cube with eye and feet), OpenCode (dark terminal with -O- face), AntiGravity (blue orbit planet), and Hermes (gold winged helmet). Mascots animate with a gentle bobbing motion during active thinking/tools and shift color palettes based on status.
Notes : Respects macOS Reduce Motion; animation clock halts when no active sessions are running.
----

## Sound Engine, Profiles & Audio Packs

What : [ Synthesized Sound Engine with Lazy Lifecycle ]
How : Synthesizes multi-partial harmonic sine cues for agent events. Automatically spins up `AVAudioEngine` on demand when an event occurs and tears it down after 2 seconds of idle to eliminate idle CPU usage and save battery.
Notes : Master volume slider and global sound enable/disable toggle.
----
What : [ Sound Profile: Quiet Glass ]
How : Clear, airy, high-register synthesized sine-wave notification tones for turn completion, attention/permission, errors, and tool use.
Notes : Clean and unobtrusive for quiet office environments.
----
What : [ Sound Profile: Soft Relay ]
How : Warm, rounded, mid-frequency synthesized tones designed to remain gentle during long coding sessions.
Notes : Smooth attack and release envelopes.
----
What : [ Sound Profile: Deep Signal ]
How : Low, resonant, measured synthesized cues with deep harmonic content and longer decay.
Notes : Low-pitched cues for subtle notifications.
----
What : [ Sound Profile: Meme ]
How : Expressive anime reaction audio clips (`yamete-kudasai.aiff` for completion/attention/errors, `brief-action.aiff` for tool use, and `skill-issue.aiff` for repeated tool failures).
Notes : Bundled inside app resources; falls back gracefully to synthesized tones if audio files are missing.
----
What : [ Custom Sound Pack Library & File Import ]
How : Users can import their own audio files (.wav, .mp3, .m4a, .aiff, .caf) into `~/.aegis/sound-packs/` directly from Settings > Sound. Imported files are automatically resampled to 44.1kHz mono PCM buffers.
Notes : Includes in-app preview and deletion buttons for imported sound files.
----
What : [ Per-Event Sound Assignment & Volume Control ]
How : Each lifecycle event (Session start, Session end, Task complete, Tool use, Error, Approval needed, Approval granted, Approval denied, Skill issue) can be independently assigned to Default, Off, or any imported custom audio file, with its own dedicated gain slider (0% to 100%).
Notes : By default, session start, session end, and tool-use sounds are set to Off to prevent notification fatigue.
----
What : [ Skill Issue Detector ]
How : Tracks tool failures within each session. If the same tool fails 3 times within a 90-second sliding window, detects a "Skill Issue", fires a `skillIssueDetected` event, and plays a dedicated sound cue (`skill-issue.aiff` in Meme profile or descending triad in synthesized profiles).
Notes : Resets immediately upon successful tool execution or session close.
----

## Power Management & Keep-Awake

What : [ Agent Execution Sleep Prevention ]
How : Creates macOS IOKit power assertions (`kIOPMAssertPreventUserIdleSystemSleep`) to prevent the Mac from sleeping while coding agents are actively running tasks or tool calls.
Notes : Configurable modes in Settings > General: Off, On Power Adapter, and On Power Adapter and Battery.
----
What : [ Battery & Thermal Power Safeguards ]
How : When running on battery, sleep prevention automatically expires after 2 hours of inactivity, and immediately releases assertions if macOS enters Low Power Mode or signals a low-battery condition.
Notes : Monitors conditions via `IOPowerSources` and `NSProcessInfo.isLowPowerModeEnabled`. Never prevents display sleep (only system idle sleep).
----

## Quota, Rate Limits & Runway Estimator

What : [ Codex Rate Limit & Quota Polling ]
How : Reads OAuth credentials from `~/.codex/auth.json` and polls OpenAI's usage endpoint (`chatgpt.com/backend-api/wham/usage`) every minute. Classifies usage windows by duration (5-hour short window and 7-day weekly window), displaying percentage remaining, reset countdown, and subscription plan type.
Notes : Detects expired tokens and surfaces actionable `auth expired — codex login` alerts. Tapping the bar cycles through available providers with data.
----
What : [ Quota Runway Forecasting ]
How : Local rate-of-consumption estimator (`QuotaRunwayEstimator`) that calculates usage velocity across polling intervals with exponential smoothing. Classifies runway health into Comfortable (green), Watch (orange), or Tight (red) based on whether current quota will sustain current pace until the reset deadline.
Notes : Purely local mathematical estimate; does not perform cost or token projection.
----

## System, Menu Bar & Utilities

What : [ macOS Status Menu Bar Extra ]
How : Native menu bar icon (`NSStatusItem`, terminal icon) showing active session count, live session list with click-to-jump actions, sound toggle, hook installer trigger, Settings shortcut, What's New dialog, and Quit option.
Notes : Operates independently of the notch window, providing persistent status even when the notch is hidden.
----
What : [ Process Sweep & Zombie Agent Cleanup ]
How : Background timer running every 5 seconds that inspects registered agent PIDs via `kill(pid, 0)` and validates kernel start timestamps (`sysctl` `kinfo_proc`) to prevent false positives from PID recycling. Also applies 5-minute inactivity timeouts for Codex and 15-minute timeouts for hook-only background sessions.
Notes : Automatically removes vanished sessions cleanly even if the agent crashed or was killed without sending `SessionEnd`.
----
What : [ Launch at Login ]
How : Registers Aegis as a native login service using macOS `SMAppService.mainApp`, starting Aegis automatically on system boot.
Notes : Configurable via toggle in Settings > General.
----
What : [ First-Run Onboarding & What's New ]
How : Interactive onboarding wizard featuring animated starfield background (`CosmicBackground`), live faux notch preview, theme picker, provider verification, and confetti celebration (`ConfettiSwiftUI`). Includes a versioned "What's New" modal shown after updates.
Notes : Never steals focus on first launch; available anytime via Menu Bar > Welcome / What's New.
----
What : [ Unix Socket IPC Protocol (/tmp/aegis.sock) ]
How : Centralized Unix domain socket server accepting newline-delimited JSON messages from provider bridge shims. Normalizes diverse agent event payloads into 12 canonical lifecycle events: `SessionStart`, `SessionEnd`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `PermissionRequest`, `Stop`, `Notification`, `SubagentStart`, `SubagentStop`, `PreCompact`, and `ActivityUpdate`.
Notes : Rejects non-canonical events to prevent socket pollution or phantom sessions.
----

## Keyboard Shortcuts Summary

What : [ Global Voice Dictation Shortcut ]
How : Double-press `Shift` (or Left Shift / Right Shift) to start/stop dictation in Toggle mode, or hold `Shift` in Hold mode. Press `Escape` to cancel.
Notes : Configurable and resettable in Settings > Transcription.
----
What : [ Global Hermes Voice Handoff Shortcut ]
How : Hold `Control-Option-Space`, speak, and release to send task prompt to Hermes.
Notes : Registered globally via Carbon `RegisterEventHotKey`.
----
What : [ Settings Shortcut ]
How : Press `Command-,` (Command-Comma) while Aegis is active or selected from menu bar to open Settings window.
Notes : Replaces default SwiftUI scene with full macOS Settings window.
----
What : [ Menu Bar Keyboard Shortcuts ]
How : Press `s` in the menu bar dropdown to toggle sound effects; press `q` (or Command-Q) to quit Aegis.
Notes : Configured as key equivalents in `MenuBarManager`.
----
