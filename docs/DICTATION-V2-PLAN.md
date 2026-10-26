# Aegis dictation v2: research and implementation plan

Research date: 2026-10-10. Scope: replace the current dictation engine and experience with the requested BetterWispr behaviors, while continuing Aegis's cleanup. The approved implementation is now in the working tree. The sections below preserve the source research and design decisions; delivery and verification status follow here.

## Current delivery and evidence

The dictation upgrade replaces Hermes transcription with pinned FluidAudio 0.17.5 and Parakeet TDT v3, the notch with a bottom capsule, and focus restoration with a live field check and clipboard fallback. It includes hold/single-press/double-press modes, microphone/language settings, bounded correction learning, editable vocabulary, English voice commands, and aggregate-only insights. The existing recorder, permission setup, cancellation and output-mute safeguards remain.

The new code is uncommitted. `swift test` passes 185 tests, including 24 dictation tests. `./scripts/build-app.sh` produces `build/Aegis.app`; strict signature verification passes. Isolated renders checked the waveform, recovery card and settings layout without loading the model. The package includes source license notices and no model weights. FluidAudio's bundled text-to-speech resources are unused by this ASR path and are not shipped.

After explicit approval to install and relaunch, the new build is installed at `/Applications/Aegis.app` and running through the existing launchd service. Installed/build executable hashes match, strict signature verification passes, and the new process owns `/tmp/aegis.sock` and receives hooks. Real microphone capture, end-to-end dictation delivery and latency remain unverified.

Cleanup is committed as `5659ed2` (`Remove unused sound events, Hermes voice handoff, and Mysa`). The updated application is installed at `/Applications/Aegis.app` and was restarted through its existing launchd service. Installed/build binary hashes match, strict signature verification passed, and the running process owns `/tmp/aegis.sock` and receives session hooks. Cleanup verification included 191 passing Swift tests and a release build. These checks do not establish audible playback or live dictation behavior.

Reference: [BetterWispr](https://github.com/opennookorg/betterwispr/tree/c37fe2ce98cba3cd490c28574617dc497b0684b8), pinned to commit `c37fe2ce98cba3cd490c28574617dc497b0684b8`, version 0.1.4. Inspected source locally in `/tmp/aegis-betterwispr-research`, alongside Aegis's current implementation. The installed BetterWispr is also 0.1.4; matching versions do not establish that its binary is from this exact commit.

Inspected the installed app's Settings and Insights surfaces and the supplied model screenshot. Its current setup is Right Shift, press to toggle, automatic microphone, automatic language, auto-paste, and correction learning. Inspected model filenames and metadata without loading them. No local inference, microphone recording, or latency benchmark was performed during research.

## Recommendation

Use **FluidAudio directly with Parakeet TDT v3**, a single retained engine instance, and a small native bottom capsule. Replace the Hermes transcription subprocess and the old focus-restoration path. Keep the existing Aegis settings shell, permissions, cancellation safeguards, microphone preference handling, and output-mute restoration.

Do not make BetterWisprCore a dependency. It includes providers and features outside this request. Adapt only the useful focused pieces, with attribution where code is copied. The initial implementation has one model, one recording flow, one output path, a vocabulary list, and aggregate insights. No provider registry or new framework is needed.

Keep the interface sparse: the bottom waveform and its necessary controls; settings rows with short labels; compact insights. No eyebrows, decorative subtitles, explanatory paragraphs under routine controls, duplicated status text, or extra cards around individual settings. Add a short instruction only when it explains an unfamiliar action or helps recover from an error. Keep visible labels, accessible control names, focus behavior and usable hit targets.

Reuse the current recorder, shortcut handling and settings layout. Add only the engine integration and the requested behavior each existing component lacks. Replace obsolete paths instead of leaving parallel implementations. No general model manager, new design system, or speculative configuration. Apply better-writing to the copy and better-interface to the completed dictation flow; this plan is not a rendered interface review.

## What the reference actually does

### 1. Immediate feedback and the bottom waveform

BetterWispr creates its nonactivating `NSPanel` in advance. Starting dictation updates the visible state before asynchronous microphone preparation. Its panel cannot become the key or main window, so displaying it does not move the text cursor. The panel is centered on the screen under the pointer and positioned from that screen's visible frame, above the Dock. [Panel setup and placement](https://github.com/opennookorg/betterwispr/blob/c37fe2ce98cba3cd490c28574617dc497b0684b8/Sources/BetterWispr/App/CapsuleController.swift#L1-L8), [panel lifecycle](https://github.com/opennookorg/betterwispr/blob/c37fe2ce98cba3cd490c28574617dc497b0684b8/Sources/BetterWispr/App/CapsuleController.swift#L90-L139), [start sequence](https://github.com/opennookorg/betterwispr/blob/c37fe2ce98cba3cd490c28574617dc497b0684b8/Sources/BetterWispr/App/AppModel.swift#L234-L282).

The recording pill is approximately 96–108 × 28 points. Its waveform uses recent microphone levels drawn with `Canvas` and `TimelineView`, with narrow bars, 60 ms history slots, horizontal movement and a fade at the older edge. The surface uses a short, zero-bounce spring, material background, stable hover bounds, Reduce Motion and Reduce Transparency support. It is a level-history visualization, not a frequency spectrum. [Recording layout](https://github.com/opennookorg/betterwispr/blob/c37fe2ce98cba3cd490c28574617dc497b0684b8/Sources/BetterWispr/Features/Recording/CapsuleView.swift#L385-L430), [material and waveform](https://github.com/opennookorg/betterwispr/blob/c37fe2ce98cba3cd490c28574617dc497b0684b8/Sources/BetterWispr/Features/Recording/CapsuleView.swift#L553-L673).

**Aegis plan:** replace `DictationNotch.swift` with a precreated bottom panel and compact state-driven view. Show it immediately after recognizing the shortcut, before AX calls, device enumeration or model work. Use real audio levels, bounded redraws and larger invisible click targets around compact controls. Anchor to the pointer's screen at session start and keep it stable for that session. Respect Dock, Spaces, full-screen apps and accessibility settings. No dictation UI appears in the notch.

Use a single surface for `starting → listening → transcribing → idle/copied/error`. Hold mode needs the waveform and cancel affordance; toggle mode also needs a finish button. Successful paste collapses quietly. Clipboard fallback displays a brief **“Copied to clipboard”** message. A clipboard write failure retains only the current result in a selectable, dismissible recovery card. Keep the capsule hidden while idle initially; no extra always-visible controls are needed.

### 2. Engine, existing model, and language settings

BetterWispr pins **FluidAudio 0.17.5**. Its Parakeet provider loads compiled local models with `AsrModels.loadLocal`, retains an `AsrManager`, and creates a fresh decoder state for each recording. Model preparation begins at app launch and concurrent requests share one preparation task. Dictation uses finished-recording batch inference; the moving waveform does not imply streaming text recognition. [Package dependencies](https://github.com/opennookorg/betterwispr/blob/c37fe2ce98cba3cd490c28574617dc497b0684b8/Package.swift#L12-L28), [model lifecycle](https://github.com/opennookorg/betterwispr/blob/c37fe2ce98cba3cd490c28574617dc497b0684b8/Sources/BetterWisprCore/Speech/ParakeetProvider.swift#L119-L149), [transcription](https://github.com/opennookorg/betterwispr/blob/c37fe2ce98cba3cd490c28574617dc497b0684b8/Sources/BetterWisprCore/Speech/ParakeetProvider.swift#L200-L225), [shared preparation](https://github.com/opennookorg/betterwispr/blob/c37fe2ce98cba3cd490c28574617dc497b0684b8/Sources/BetterWispr/App/AppModel.swift#L464-L498).

The installed model already exists at:

```text
~/Library/Application Support/BetterWispr/Models/Parakeet/parakeet-tdt-0.6b-v3/
```

It contains the expected `Encoder.mlmodelc`, `Decoder.mlmodelc`, `Preprocessor.mlmodelc`, `JointDecisionv3.mlmodelc`, and `parakeet_vocab.json` files. Names and metadata match the pinned v3 loader; actual loading remains unverified. The installed marker alone is insufficient validation. [FluidAudio's required v3 files](https://github.com/FluidInference/FluidAudio/blob/0b1f46289fe27d95b5e66ad8be46e64f5ee02ae7/Sources/FluidAudio/ModelNames.swift#L464-L507), [local loader](https://github.com/FluidInference/FluidAudio/blob/0b1f46289fe27d95b5e66ad8be46e64f5ee02ae7/Sources/FluidAudio/ASR/Parakeet/SlidingWindow/TDT/AsrModels.swift#L258-L309).

**Aegis plan:** pin FluidAudio 0.17.5 for the first migration, with the existing `DictationTranscriptionRunner` as a focused wrapper around FluidAudio’s actor. Import a validated copy of the existing model into Aegis-owned Application Support storage, so removing BetterWispr does not break Aegis. Stage the copy, validate its file contract, then atomically adopt it; keep the BetterWispr originals untouched. Do not put weights in Git or the application bundle. Provide an import-folder recovery action if discovery fails; no model marketplace or downloader is needed for this scope.

Prepare the engine asynchronously when dictation is enabled, keep it resident, and share preparation work. The capsule and microphone startup must not wait for model loading. If the first recording finishes before preparation, show the transcribing state while it completes. Use generation tokens to discard cancelled/obsolete results; serialize inference because cancelling a Swift task may not interrupt CoreML work immediately. Delete temporary recordings after completion, failure or cancellation, and clean abandoned Aegis recording files on startup.

Use Auto plus Parakeet v3's 25 supported languages. Its language parameter chiefly filters token candidates by Latin, Cyrillic or Greek script; French additionally has a token blocklist. It is not translation or a guarantee of strict language selection. Arabic is outside this model's published catalog. Keep implementation detail out of the setting's UI: use a normal Language picker with Auto as default. [Supported languages](https://github.com/opennookorg/betterwispr/blob/c37fe2ce98cba3cd490c28574617dc497b0684b8/Sources/BetterWisprCore/Speech/SpeechProvider.swift#L32-L55), [FluidAudio language filtering](https://github.com/FluidInference/FluidAudio/blob/0b1f46289fe27d95b5e66ad8be46e64f5ee02ae7/Sources/FluidAudio/Shared/TokenLanguageFilter.swift#L3-L68), [decoder behavior](https://github.com/FluidInference/FluidAudio/blob/0b1f46289fe27d95b5e66ad8be46e64f5ee02ae7/Sources/FluidAudio/ASR/Parakeet/SlidingWindow/TDT/Decoder/TdtDecoderV3.swift#L627-L711).

FluidAudio requires a Swift 6-capable toolchain and supports macOS 14; this Mac has Swift 6.3. The implementation declares Swift tools 6.2 to disable unused dependency traits, while explicitly retaining Swift 5 language mode for Aegis. No repository-wide language migration was needed. [FluidAudio manifest](https://github.com/FluidInference/FluidAudio/blob/0b1f46289fe27d95b5e66ad8be46e64f5ee02ae7/Package.swift#L1-L35).

### 3. Insertion and clipboard fallback

The reference does **less cursor detection than its behavior suggests**. It captures the frontmost application, checks that the same app remains frontmost and accessibility is allowed, then sends targeted Cmd+V. It does not validate an editable field or acknowledge actual paste success. It never reactivates the original app. Its clipboard restoration waits 750 ms and respects clipboard change counts. [Complete output implementation](https://github.com/opennookorg/betterwispr/blob/c37fe2ce98cba3cd490c28574617dc497b0684b8/Sources/BetterWisprCore/Integrations/TextOutput.swift#L25-L72).

Aegis currently activates and raises the saved app/window, restores focus, waits for focus stability, guesses/restores the selection and polls for paste verification. That machinery is the part to remove.

**Aegis plan:** retain only a lightweight destination identity, using bounded AX access off the immediate presentation path. At delivery, check that the same application and editable field are still focused and that the field is not secure. Use the live caret/selection in that field. Never raise a window, activate an app, move the caret, set the old selection, or retry insertion automatically. If focus changed, no input is active, access is unavailable, or the field cannot be identified reliably, copy and show the brief bottom message.

Send one paste event to a verified destination. Preserve the existing clipboard snapshot/change-count guard, but restore the previous clipboard only after a bounded, reliable readback confirms insertion. When the application cannot expose a useful readback, leave the dictated text on the clipboard; avoid a long blocking verification loop or claiming confirmed insertion. Text must remain recoverable without introducing history. Electron accessibility support can be enabled lazily and cached per app; it must not delay capsule presentation. Secure fields never receive dictation or correction monitoring.

This conservative fallback needs hands-on validation in native, browser and Electron editors. macOS does not provide a universal editable-field or paste-acknowledgement API, so universal compatibility cannot be established from source inspection.

### 4. Shortcuts

BetterWispr uses event monitors for modifier-only keys, including left/right variants, and Carbon hotkeys for chords. It supports hold and single-press toggle; its hold mode also turns a tap shorter than 300 ms into hands-free recording. Aegis already has useful guards for ordinary Shift typing, repeats, cancellation and stale events. [Shortcut registration](https://github.com/opennookorg/betterwispr/blob/c37fe2ce98cba3cd490c28574617dc497b0684b8/Sources/BetterWispr/App/GlobalShortcut.swift), [gesture handling](https://github.com/opennookorg/betterwispr/blob/c37fe2ce98cba3cd490c28574617dc497b0684b8/Sources/BetterWispr/App/AppModel.swift#L183-L232).

**Aegis plan:** reuse the existing Shift-key selector and shortcut handler. Expose clear **Hold to talk** and **Press to toggle** modes, including Right Shift with single-press toggle to match the installed reference. Preserve existing configured shortcuts during migration instead of silently changing muscle memory. Keep ordinary-typing and repeat guards, Esc cancellation, and balanced press/release handling. A general shortcut recorder and the reference's hybrid quick-tap behavior are outside the initial implementation.

### 5. Microphone and capture quality

BetterWispr uses an input-only Audio Queue with four 20 ms buffers, native device format and asynchronous startup. Its recorder derives levels from fixed-duration RMS windows, with an adaptive noise floor, peak decay and smoothing. The silence check is an amplitude gate, not another speech model. Explicit microphone UIDs fall back to the system default if disconnected. [Capture setup](https://github.com/opennookorg/betterwispr/blob/c37fe2ce98cba3cd490c28574617dc497b0684b8/Sources/BetterWisprCore/Audio/MicrophoneInput.swift#L130-L200), [device selection](https://github.com/opennookorg/betterwispr/blob/c37fe2ce98cba3cd490c28574617dc497b0684b8/Sources/BetterWisprCore/Audio/AudioInputs.swift#L16-L53), [meter](https://github.com/opennookorg/betterwispr/blob/c37fe2ce98cba3cd490c28574617dc497b0684b8/Sources/BetterWisprCore/Audio/AudioRecorder.swift#L216-L356).

**Aegis plan:** first retain the existing native recorder and device monitor, improve its level history/smoothing, and feed its finished audio file to FluidAudio's converter. This isolates the engine replacement and avoids rewriting working capture code just to match a different API. Measure startup and device recovery. Replace the recorder internals with a single-consumer Audio Queue only if those measurements reproduce a problem that this change addresses; do not import BetterWispr's shared meeting-capture infrastructure.

Expose Automatic (system default), connected microphones and the remembered disconnected choice. Use one calibrated silence threshold initially, without extra sensitivity controls. Keep the existing mute-while-recording setting and restore output on every exit path. Handle same-device Bluetooth format changes as well as unplugging. Show listening only after capture actually starts. Cold model loading and microphone startup need separate measurements.

### 6. Learn from corrections

BetterWispr watches the pasted field for up to 30 seconds at 500 ms intervals, waits for edits to settle, and extracts small word/phrase substitutions inside the inserted text. The learner uses word alignment and filtering rather than model training. Learned replacements are whole-word, ordered longest first and noncascading. [Correction watcher](https://github.com/opennookorg/betterwispr/blob/c37fe2ce98cba3cd490c28574617dc497b0684b8/Sources/BetterWisprCore/Integrations/CorrectionWatcher.swift#L12-L85), [learner](https://github.com/opennookorg/betterwispr/blob/c37fe2ce98cba3cd490c28574617dc497b0684b8/Sources/BetterWisprCore/Transcription/CorrectionLearner.swift), [replacement logic](https://github.com/opennookorg/betterwispr/blob/c37fe2ce98cba3cd490c28574617dc497b0684b8/Sources/BetterWisprCore/Transcription/VocabularyProcessor.swift).

Its optional acoustic vocabulary booster uses a **separate CTC model**. That is an additional inference pass, not part of the TDT v3 bundle. [Booster behavior](https://github.com/FluidInference/FluidAudio/blob/0b1f46289fe27d95b5e66ad8be46e64f5ee02ae7/Sources/FluidAudio/ASR/Parakeet/SlidingWindow/CustomVocabulary/VocabularyBoostingSession.swift#L1-L31).

**Aegis plan:** add Learn from corrections plus a small editable Vocabulary list with add/edit/delete. Learn only from a confirmed insertion into the same nonsecure field; stop when focus changes, a new dictation starts, the app exits, or the timeout expires. Retain surrounding text only in memory for that bounded observation. Persist only the learned phrase pair, never its source transcript. Ignore large rewrites and ambiguous common-word changes. Proper-name spelling hints that cannot safely become replacements must not silently rewrite normal prose. Skip the CTC booster to honor the one-model scope; correction learning works independently through text replacements.

### 7. Voice commands

BetterWispr implements deterministic English text transforms for punctuation, new lines/paragraphs, symbols, spoken numbers and “scratch that.” It guards some literal uses such as “the Oxford comma.” Its “scratch that” edits the current dictated utterance; it does not delete existing editor text. [Command parser](https://github.com/opennookorg/betterwispr/blob/c37fe2ce98cba3cd490c28574617dc497b0684b8/Sources/BetterWisprCore/Transcription/VoiceCommands.swift#L1-L150).

**Aegis plan:** adapt the bounded command parser and relevant number handling, with an enable switch and concise command list. Begin with English commands matching the reference: comma, full stop/period, question mark, exclamation mark, colon/semicolon, new line, new paragraph, at sign, percent and scratch that. Preserve literal-mention guards. Run learned command-spelling corrections before command parsing and ordinary vocabulary replacements afterward.

Commands must be language-gated. A selected non-English language bypasses English transforms. With Auto, use a conservative English-text check; ambiguous text passes through unchanged. This gate is independent of Parakeet's script hint, which is not reliable language identification. No extra LLM, tone rewriting or generated email formatting is required.

### 8. Insights without history

BetterWispr derives its insights from saved `Transcript` records. Its UI explicitly stops counting new dictations when history is disabled. Its metrics include words, dictations, duration, pace, estimated time saved, daily usage, apps, hours and vocabulary fixes. [Aggregation](https://github.com/opennookorg/betterwispr/blob/c37fe2ce98cba3cd490c28574617dc497b0684b8/Sources/BetterWisprCore/Domain/UsageInsights.swift#L16-L137), [history dependency in the UI](https://github.com/opennookorg/betterwispr/blob/c37fe2ce98cba3cd490c28574617dc497b0684b8/Sources/BetterWispr/Features/Insights/InsightsView.swift#L32-L68).

**Aegis plan:** create a small atomic local aggregate store, updated once per completed dictation. Store day buckets with counts, words and speaking duration. Persist no text, audio, app activity, window titles, field contents or individual dictation records. Use a stable day-key policy so timezone changes do not rewrite previous totals. Allow resetting insights independently of Vocabulary.

Keep Insights to four metrics (words, dictations, speaking pace, estimated time saved) and one daily chart with 7-day, 30-day and all-time filters. Use native Swift Charts within Aegis's settings shell. Keep the time-saved formula visibly an estimate; use an explicit assumed typing pace rather than implying measured productivity. Skip app/hour breakdowns, streaks and word rankings. No History screen or transcript database.

## Small implementation boundary

```text
Shortcut → DictationController → recorder → DictationTranscriptionRunner
                 ↓                               ↓
           bottom capsule                commands + vocabulary
                                                 ↓
                                         live destination check
                                         ↙                  ↘
                                  one paste              clipboard
                                     ↓                      ↓
                            bounded correction watch   brief feedback
                                     └──── aggregate counters ────┘
```

| Existing area | Planned change |
| --- | --- |
| `DictationController.swift` | Keep lifecycle owner, generation tokens, cancellation and watchdogs; present UI first and call the native engine. |
| `DictationTranscriptionConfiguration.swift`, `DictationTranscriptionRunner.swift` | Remove Hermes discovery, Python subprocess and transcription environment configuration; replace with the focused Parakeet engine and model importer. |
| `DictationNotch.swift` | Replace with bottom `DictationCapsule` view/controller, with no notch coordination. |
| `DictationInsertion.swift` | Delete activation, window raising, focus settling and saved-caret restoration. Keep bounded field checks, secure-field handling and safe clipboard ownership. |
| `DictationAudioRecorder.swift`, `DictationMicrophones.swift` | Reuse capture/device ownership; improve level data, default-device behavior and recovery as required. |
| `DictationShortcut.swift` | Reuse the Shift-key selector, implement single-press toggle, preserve existing typing safeguards and migrate preferences. |
| `DictationPermissionSetup.swift`, `DictationOutputMute.swift` | Retain focused existing behavior and update wording/references where the engine changes. |
| `DictationTranscriptController.swift` | Remove accumulating uninserted transcript storage and its Settings section; retain only the current recovery result in controller state. |
| Settings store and `SettingsView.swift` | Refine Transcription controls; add compact Vocabulary and Insights destinations in the existing shell. |
| New focused helpers | Command processing, correction watcher/vocabulary persistence, and aggregate insights; avoid parallel service/protocol hierarchies. |

Remove obsolete configuration tests and update existing dictation tests to the new behavior. Hermes session monitoring remains an independent Aegis integration; replacing the transcription backend does not require deleting that integration.

## Implementation order and acceptance

1. **Complete core dictation flow.** Add the pinned engine and existing-model import; warm loading; replace the notch with the bottom capsule; replace insertion/focus restoration; preserve cancellation, secure-field protection and recovery. Acceptance: a complete record → result → paste/copy flow with no Python/Hermes transcription dependency or forced app switching.
2. **Controls and input polish.** Existing shortcut controls with hold/toggle behavior, microphone/language settings, real waveform, device recovery and accessibility. Acceptance: ordinary typing does not trigger dictation; the visible state tracks actual capture; the capsule behaves correctly across screens, Spaces and display settings.
3. **Corrections and commands.** Bounded learning, editable vocabulary and deterministic voice commands. Acceptance: repeated name corrections improve later text; unrelated edits are ignored; commands handle punctuation without corrupting literal mentions or non-English prose.
4. **Insights and final removal pass.** Aggregate-only metrics and charts; remove old transcript UI, obsolete tests/helpers and stale documentation. Acceptance: counts survive relaunch with no transcript/audio history, and resetting insights leaves Vocabulary intact.

Keep these as independently reviewable commits. Each stage should leave a functional application, with its own applicable verification; no placeholder controls or incomplete feature labels.

## Verification and remaining uncertainty

- Reuse and amend existing Swift tests first. Add only uncovered main/failure cases, respecting the project's limit of one main path and one critical failure path for new tests; no new test framework or unrelated coverage work.
- Exercise lifecycle cancellation during preparation/inference and late callbacks; validate that cancelled work cannot paste, count twice, leak a microphone or leave output muted. Engine-unit tests use a controlled test seam, not local inference.
- Check destination safety, Unicode/caret handling and clipboard change-count protection, including focus switching, no editable field, password input and a user copying something during delivery. Never duplicate a paste to recover an uncertain result.
- Validate command/language boundaries, learned replacement boundaries and aggregate persistence, including relaunch and reset. Inspect Aegis storage/logging for transcript or audio retention.
- Build/package/sign through the existing scripts. Keep model assets outside the package. Check FluidAudio resolution, macOS 14 availability, current SDK behavior and any runtime resources brought by its dependencies.
- Hands-on acceptance needs native text fields, browser inputs/contenteditable and Electron editors; multiline selections; no-input clipboard fallback; denied AX access; microphone unplug/Bluetooth format changes; Escape; quick restart; multiple screens/full-screen; Reduce Motion/Transparency and VoiceOver. Live speech/model performance remains unverified by this research.
- Measure recognized-shortcut → capsule, shortcut → first captured sample, stop → transcript, and stop → delivery separately, cold and warm. Target visible feedback in the first frame or two; report measured distributions instead of promising BetterWispr's benchmark numbers. Inspect idle CPU and resident engine memory. A cold CoreML load can be substantially slower than warm recognition, so the UI must communicate preparation without freezing or showing a false listening state.

The largest remaining runtime questions are CoreML loading of the existing copy, actual startup/decoding times on this Mac, and AX behavior in the editors used daily. None is resolved by source similarity alone.

## Source reuse

BetterWispr and the pinned FluidAudio source are Apache-2.0 licensed. Preserve required attribution/license notices for adapted source, and record the pinned upstream revisions. Reuse behavior and appropriate code while keeping Aegis's branding and existing application structure. [BetterWispr license](https://github.com/opennookorg/betterwispr/blob/c37fe2ce98cba3cd490c28574617dc497b0684b8/LICENSE), [FluidAudio license](https://github.com/FluidInference/FluidAudio/blob/0b1f46289fe27d95b5e66ad8be46e64f5ee02ae7/LICENSE).

Model assets have separate notices: NVIDIA's v3 card declares CC BY 4.0. The converted Core ML card has conflicting metadata (`cc-by-4.0`) and prose (Apache 2.0). The initial implementation imports the user's existing copy and does not redistribute weights. Resolve that discrepancy and record the applicable model notices before any future bundled distribution. [NVIDIA model card](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3#license/terms-of-use), [Core ML conversion card](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml).

## Interface review

### Scope and Coverage

Full review narrowed to the new dictation capsule and Transcription settings, using Aegis's native AppKit/SwiftUI controls. Source inspection covers the supporting Vocabulary and Insights views; those views were not rendered interactively.

| Domain | Evidence inspected | Result |
| --- | --- | --- |
| Accessibility | Capsule focus rules, control labels, announcements, contrast/motion preferences; settings labels | Clear within source review; VoiceOver and system preferences not verified live |
| Layout | Isolated waveform/recovery/settings renders and fixed-size panel test | Oversized recovery panel fixed |
| Writing | Settings, command guidance, empty states and recovery text | Clear |
| Typography | `better-typography` unavailable | Not reviewed |
| Colors | `better-colors` unavailable | Not reviewed |
| UI | `better-ui` unavailable | Not reviewed |

### Findings

| # | Severity | Domain | Location | Before | After | Why |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | HIGH | layout | `Sources/Aegis/Transcription/DictationCapsule.swift:125` | Hosting view expanded the recovery panel beyond its intended frame | Automatic sizing disabled; panel owns its frame | Keeps text and copy/dismiss controls visible |
| 2 | LOW | layout | `Sources/Aegis/Transcription/DictationSettingsView.swift:74` | Import control occupied a separate mostly empty row | Model and Import share one row | Removes wasted space |

Both findings are fixed. No actionable findings remain within the reviewed scope.

### Considered but Rejected

| Location | Candidate | Rejected because |
| --- | --- | --- |
| Transcription settings | New shortcut recorder and sensitivity controls | Existing Shift controls satisfy this scope with less UI and code |
| Insights | App breakdowns, streaks and transcript history | Four aggregates and the daily chart meet the request without retaining dictations |

### Verification

- `swift test`: 185 tests pass; existing lifecycle and paste tests updated, with one new main-path and one new failure-path test. No model inference is invoked.
- Isolated XCTest renders: `/tmp/aegis-capsule.png`, `/tmp/aegis-capsule-recovery.png`, `/tmp/aegis-dictation-settings.png`. Temporary image-export code was removed after inspection; the panel sizing/focus assertion remains.
- `./scripts/build-app.sh` and `codesign --verify --deep --strict build/Aegis.app`: pass.
- **Not verified:** model loading/inference, live microphone/device behavior, external-app paste, multi-screen/full-screen use, VoiceOver, reduced-motion/transparency appearance and measured latency.

### Verdict

Approve — source and isolated-render review only; this is not a complete six-domain or live dictation sign-off.
