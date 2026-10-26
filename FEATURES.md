# AEGIS Features

Comprehensive list and technical summary of all features, capabilities, subsystems, and integrations in AEGIS.

---

## Notch Window & UI Shell

What : [ Top-Center Borderless Notch Window ]
How : Borderless AppKit panel (`NSPanel`, `.borderless`, `.nonactivatingPanel`) hosting SwiftUI that centers itself seamlessly over the physical MacBook display notch (`safeAreaInsets.top`) or renders as a clean top-centered bar on non-notch Macs and external monitors (`ScreenDetector.notchPanelFrame`). Responds dynamically to display connection and reconfiguration events (`didChangeScreenParametersNotification`).
Notes : Does not steal focus from active applications; automatically remains hidden when no agent sessions or pending actions require attention.
----
What : [ Compact Notch & Live Aggregate Status ]
How : Shows the most recently active provider's pixel mascot, an aggregate status dot, and the active-session count. The notch is passive: it neither expands nor handles clicks. Orange indicates a provider waiting for input, cyan thinking, and green other active states. It hides when no sessions remain active.
----

## Supported Agents & Integrations

- Codex: managed lifecycle hooks in `~/.codex/hooks.json` and read-only desktop session monitoring. Permission hooks report waiting status and exit without returning a decision.
- Hermes: lifecycle hooks in `~/.hermes/config.yaml` and its profiles, plus read-only desktop SQLite monitoring. Pre-tool hooks never wait for Aegis approval.
- OpenCode: a managed plugin reports lifecycle, permission, and question events through the bridge. It does not call approval or question-answer APIs.
- AntiGravity: managed lifecycle hooks in `~/.gemini/config/hooks.json`; native provider approval handling stays unchanged.
- Installers run at launch and can be rerun from the menu bar or Settings. Existing foreign hooks and user approval policies are preserved.
- Parent/child session tracking remains active. Show subagents controls their contribution to the compact count; waiting child agents remain visible until provider progress.
- Permissions and questions are answered in the originating app or terminal. Aegis observes waiting status for the compact indicator and power management.

## Voice Dictation & Input Insertion

- Parakeet TDT v3 through FluidAudio, loaded locally from an imported model. Auto or one of its 25 supported languages.
- A compact bottom capsule shows microphone levels, cancellation, processing and clipboard feedback without taking focus.
- Shift shortcuts support hold, single-press toggle and the existing double-press toggle, with left/right key selection and typing guards. Escape cancels.
- Paste uses the live selection only while the same editable field remains focused. Otherwise text stays on the clipboard. A bounded readback restores the previous clipboard only after confirmed insertion, respecting newer clipboard changes.
- The microphone picker follows the system default or a remembered device. Recording cancels if its device disappears or its format changes. Optional system-audio muting is restored on exit.
- English voice commands support punctuation, paragraphs, symbols and removal of the last sentence in the current utterance. Ambiguous automatic-language input remains literal.
- Optional correction learning observes only the just-inserted text for a bounded time. Vocabulary entries can be added, edited or deleted.
- Insights stores daily word counts, dictation counts and speaking duration. There is no transcript history. Temporary recordings are removed after use; clipboard failures keep only the current result for recovery.

## Visual Themes & Customization

Theme choices preserve compact typography: Aegis, Liquid Glass, and Brutalist use native type; Default, Retro Pixel, and Terminal use monospaced type; Web-Slinger uses rounded type with the Codex mascot mask. The compact notch stays black and borderless. Settings and onboarding show compact previews.

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
How : Clear, airy, high-register synthesized sine-wave notification tones for session endings and errors.
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
How : Expressive anime reaction audio (`yamete-kudasai.aiff`) for session endings and errors.
Notes : Bundled inside app resources; falls back gracefully to synthesized tones if audio files are missing.
----
What : [ Sound Profile: F1 ]
How : Formula 1 audio clips for session endings (`completion.aiff`) and errors (`failure.aiff`).
Notes : Bundled inside app resources with synthesized fallback.
----
What : [ Custom Sound Pack Library & File Import ]
How : Users can import their own audio files (.wav, .mp3, .m4a, .aiff, .caf) into `~/.aegis/sound-packs/` directly from Settings > Sound. Imported files are automatically resampled to 44.1kHz mono PCM buffers.
Notes : Includes in-app preview and deletion buttons for imported sound files.
----
What : [ Per-Event Sound Assignment & Volume Control ]
How : Each sound event (Session end and Error) can be independently assigned to Default, Off, or any imported custom audio file, with its own dedicated gain slider (0% to 100%).
Notes : Session-end and error sounds are enabled by default on new installs. Existing custom assignments, Off choices, and volumes for these events are preserved.
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

## System, Menu Bar & Utilities

What : [ macOS Status Menu Bar Extra ]
How : Native menu bar icon (`NSStatusItem`, terminal icon) offering the sound toggle, hook installer, Settings, Welcome, What's New, and Quit actions.
Notes : Operates independently of the notch window, providing access to app controls even when the notch is hidden.
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
How : Centralized Unix domain socket server accepting four-byte big-endian length-prefixed JSON messages from provider bridge shims. Normalizes diverse agent event payloads into 12 canonical lifecycle events: `SessionStart`, `SessionEnd`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `PermissionRequest`, `Stop`, `Notification`, `SubagentStart`, `SubagentStop`, `PreCompact`, and `ActivityUpdate`.
Notes : Connections close after the event is read; there is no decision-response channel. Rejects non-canonical events to prevent phantom sessions.
----

## Keyboard Shortcuts Summary

What : [ Global Voice Dictation Shortcut ]
How : Press or double-press `Shift` (or Left Shift / Right Shift), according to the selected toggle mode, or hold `Shift` in Hold mode. Press `Escape` to cancel.
Notes : Configurable and resettable in Settings > Transcription.
----
What : [ Settings Shortcut ]
How : Press `Command-,` (Command-Comma) while Aegis is active or selected from menu bar to open Settings window.
Notes : Replaces default SwiftUI scene with full macOS Settings window.
----
What : [ Menu Bar Keyboard Shortcuts ]
How : Press `s` in the menu bar dropdown to toggle sound effects; press `q` (or Command-Q) to quit Aegis.
Notes : Configured as key equivalents in `MenuBarManager`.
----
