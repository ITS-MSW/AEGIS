# AEGIS macOS Permissions & Security Guide

Aegis is a native macOS utility that monitors AI coding agents, performs global voice dictation, automates window/tab switching, and prevents idle sleep while tasks execute. To deliver these capabilities, Aegis interacts with several macOS security and privacy subsystems (Transparency, Consent, and Control — TCC).

This document explains every permission Aegis requests, why it is needed, how it is handled, and how to avoid permission churn during development.

---

## 1. Permissions Matrix

| Permission Subsystem | System Setting | API / Framework | Core Aegis Capabilities | Fallback if Denied |
| :--- | :--- | :--- | :--- | :--- |
| **Accessibility** | Privacy & Security > Accessibility | `AXUIElement`, `AXIsProcessTrusted` | 1. Direct caret-position text insertion during voice dictation.<br>2. Selecting exact session tabs in Hermes Desktop. | Dictation text is copied to clipboard and saved in Settings; Hermes opens frontmost window without selecting the exact tab. |
| **Input Monitoring** | Privacy & Security > Input Monitoring | `CGEventTap` (`cghidEventTap`) | Detecting global Shift key triggers (`Double-press Shift` or `Hold Shift`) while using other apps. | Shortcut does not fire; dictation cannot be triggered via keyboard. |
| **Microphone** | Privacy & Security > Microphone | `AVCaptureDevice`, CoreAudio | 1. Capturing audio for voice dictation.<br>2. Capturing audio for Hermes push-to-talk handoff. | Dictation and voice handoff cannot record; surfaces explicit error in the UI. |
| **Automation (Apple Events)** | Privacy & Security > Automation | AppleScript, `NSAppleScript` | Scripting `System Events` to drive Hermes Desktop and terminal tabs. | Window activates to the front without sub-element targeting. |
| **Power Management** | *No user prompt required* | IOKit (`IOPMAssertion`) | Preventing system idle sleep while coding agents are executing tasks. | System follows standard OS sleep timer. |

---

## 2. In-Depth Permission Breakdown

### Accessibility (`AXIsProcessTrusted`)
- **Why It's Needed**:
  - **Voice Dictation**: Aegis does not merely simulate keystrokes. It captures the focused UI element (`kAXFocusedUIElementAttribute`), checks its role (`AXTextField`, `AXTextArea`, `AXComboBox`), enables Chromium accessibility if needed (`AXManualAccessibility`), inspects the active caret position / selection range (`kAXSelectedTextRangeAttribute`), pastes the transcript, verifies insertion, and restores the original clipboard.
  - **Hermes Desktop Tab Jump**: To switch directly to the tab matching your agent task, Aegis traverses the Hermes window hierarchy using Accessibility actions (`AXPress`, `AXRaise`).
- **Safety Safeguards**:
  - Dictation is strictly blocked in secure password fields (`kAXSecureTextFieldSubrole`).
  - If the target window or text content changes while speaking, Aegis will not overwrite your text; it copies the transcript to your clipboard instead.

### Input Monitoring (`CGEventTap`)
- **Why It's Needed**:
  - Standard macOS global hotkeys (Carbon `RegisterEventHotKey`) require a modifier plus a normal key (e.g. `Control-Option-Space`).
  - Aegis's dictation shortcut uses pure modifier taps: `Double-press Shift` or `Hold Shift`. Detecting modifier key presses while working in other applications requires a passive `CGEventTap` listening for `flagsChanged` events.
- **Safety Safeguards**:
  - The event tap is passive (`listenOnly`) and does not modify or intercept standard keystrokes.
  - Typing ordinary text (letters, numbers, symbols) while holding Shift does not trigger dictation; Aegis discards modified strokes to prevent false activations.

### Microphone (`AVCaptureDevice`)
- **Why It's Needed**:
  - Records speech when dictation is active or while `Control-Option-Space` is held for Hermes voice handoff.
  - Uses the hardware's native format and CoreAudio device resolution.
- **Safety Safeguards**:
  - The microphone is active **only** while recording is visibly engaged.
  - Audio files are stored temporarily and deleted immediately once transcription finishes.
  - Aegis does not retain or upload audio recordings to any third-party cloud.

### Apple Events / Automation
- **Why It's Needed**:
  - Used by `TerminalJumper` to target specific tabs or panes in Apple Terminal, iTerm2, and Hermes Desktop.
  - macOS displays an automation prompt the first time Aegis targets another application.

### IOKit Power Management
- **Why It's Needed**:
  - Long agent runs (compilation, multi-step debugging, large refactors) can take 10+ minutes. If the user steps away, macOS will sleep by default, terminating the agent mid-turn.
  - Aegis creates an `IOPMAssertionCreateWithDescription` assertion (`kIOPMAssertPreventUserIdleSystemSleep`) labeled `"Aegis agent execution"`.
- **Safety Safeguards**:
  - Never inhibits display sleep (your screens can still turn off to save energy).
  - Automatically disengages on battery after 2 hours of inactivity, in Low Power Mode, or upon low battery warnings.

---

## 3. The macOS Ad-Hoc Signing Trap (Crucial for Developers)

### The Problem
On macOS, TCC permissions (Accessibility, Input Monitoring, Microphone) are bound to the application's **Code Signing Designated Requirement** (CDHash and signing identity).

If you build Aegis using standard ad-hoc signing (`swift build` or `codesign -s -`):
1. Every time the executable binary changes, macOS treats it as a brand-new application.
2. The entries in **System Settings > Privacy & Security > Accessibility** still point to the *old* binary hash.
3. Even though the toggle in System Settings appears **ON**, macOS silently denies access to the newly built binary.

### The Solution: Use a Persistent Signing Identity

To preserve permissions across builds and code changes, build the app with a consistent signing identity:

```bash
AEGIS_SIGNING_IDENTITY="Aegis Development" ./scripts/build-app.sh 0.1.0
```

#### How to Create a Free Local Signing Certificate:
1. Open **Keychain Access** on your Mac.
2. In the menu bar, navigate to:
   **Keychain Access > Certificate Assistant > Create a Certificate...**
3. Configure the certificate:
   - **Name**: `Aegis Development`
   - **Identity Type**: Self-Signed Root
   - **Certificate Type**: Code Signing
4. Click **Create** and then **Done**.
5. Pass this identity when building:
   ```bash
   export AEGIS_SIGNING_IDENTITY="Aegis Development"
   ./scripts/build-app.sh
   ```
With this setup, you grant permissions once in macOS System Settings, and they will persist across all local builds and updates.

---

## 4. Resetting & Troubleshooting Permissions

If permissions become stale, confused, or unresponsive after rebuilding:

### Reset via CLI (`tccutil`)
Run the following in your terminal to clear stale permission state:

```bash
# Reset Accessibility for Aegis
tccutil reset Accessibility dev.aegis.app

# Reset Input Monitoring for Aegis
tccutil reset ListenEvent dev.aegis.app

# Reset Microphone for Aegis
tccutil reset Microphone dev.aegis.app
```

### Reset via System Settings
1. Open **System Settings > Privacy & Security > Accessibility**.
2. Select **Aegis** and click the minus (`-`) button to remove it completely.
3. Do the same under **Input Monitoring**.
4. Launch the newly built `build/Aegis.app`.
5. Aegis will trigger fresh system prompts, or you can click **"Set up dictation access…"** in **Settings > Transcription**.

---

## 5. Privacy & Security Commitments

- **100% Local IPC**: All agent communication flows over the local Unix domain socket (`/tmp/aegis.sock`). No agent data or code snippets are transmitted across external networks.
- **Zero Analytics / Telemetry**: Aegis includes no telemetry SDKs, usage trackers, or third-party monitoring services.
- **Prompt Privacy**: Task prompts submitted via Hermes Voice Handoff are streamed directly through standard input (`stdin`), preventing private prompts from leaking into system process lists (`ps`) or shell history.
- **Ephemeral Audio**: Dictation and voice recordings exist only in memory or temporary files for the duration of the speech-to-text call and are purged immediately afterward.
