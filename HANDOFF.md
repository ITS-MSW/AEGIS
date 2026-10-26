# Aegis handoff

## Repository

Location: `/Users/purpleorca/Documents/DEV/DESKTOP/AEGIS`

The repository has fresh local history with no imported upstream Git ancestry. The runnable product is an ad-hoc-signed arm64 app bundle at `build/Aegis.app`.

Build and run:

```bash
cd /Users/purpleorca/Documents/DEV/DESKTOP/AEGIS
swift build
swift build -c release
./scripts/build-app.sh 0.1.0
open build/Aegis.app
```

Earlier verification passed for the debug build, release build, bundle assembly, `Info.plist` validation, and `codesign --verify --deep --strict`. The local bundle is ad-hoc signed, not Developer ID signed or notarized.

## Compact-notch cleanup

The notch now has one passive compact presentation. Expanded sessions, replies, permission/question views, expansion settings and animations, menu-bar session jumps, and terminal navigation are removed. Background session tracking, sounds, keep-awake, and bottom dictation remain.

Permission and question events update waiting status only. The bridge exits after sending events, the socket does not return decisions, and the OpenCode plugin never calls approval APIs. Provider rules and previously saved approval files are left untouched. Updated managed hooks/plugins take effect after the next app update and provider reload; no installed app or live provider configuration was changed during this source cleanup.

Validation for this cleanup: debug build passed; all 131 retained tests passed; release build and app-bundle assembly passed with valid plist and strict code-signature verification. Generated OpenCode JavaScript and packaging-shell syntax checks passed. Live UI and native-provider prompt behavior were not exercised, and the rebuilt bundle was not installed or launched.

## Earlier follow-up improvements

- Default game-style waveforms were replaced by restrained sine-partial notification tones. Session start/end and tool-use chatter default to Off.
- Command-comma now opens the real Settings window instead of the empty SwiftUI settings scene.
- Codex Desktop is monitored through appended rollout JSONL events in `~/.codex/sessions`; the previous redundant `codex app-server` subprocess was removed.
- Hermes Desktop is monitored through new desktop-only message rows in `~/.hermes/state.db` using SQLite WAL-safe reads.
- Follow-up GUI evidence: [`docs/test-evidence/17-followup-results.txt`](docs/test-evidence/17-followup-results.txt).

## Scope completed

- Removed 13 of the 17 upstream agent providers and retained exactly Codex, Hermes, OpenCode, and AntiGravity.
- Deleted 56 tracked upstream files across provider implementations, provider artwork, old documentation/site assets, credits, licensing, funding, updater, and demo tooling.
- Removed all 9 requested upstream-identity search targets from the working tree, together with upstream repository URLs, update feed, screenshots, and logo artwork.
- Renamed the app, products, targets, bundle identity, socket, config domain, bridge, launchers, defaults domain, hook marker, and on-disk state to Aegis.
- Preserved the bridge, canonical lifecycle events, in-memory session tracking and process sweep, sound engine, and mascot engine.
- Rewrote the README, engineering spec, and changelog in English.

`AIProvider.all` is the source of truth and contains exactly:

```swift
[.codex, .hermes, .opencode, .antigravity]
```

## Historical computer-use results

These results predate the compact-notch cleanup and are not runtime validation of the current source.

| Checklist item | Result | Evidence |
| --- | --- | --- |
| 1. Launch, top-center borderless notch, no focus steal | Pass | [`docs/test-evidence/01-launch-not-focused.png`](docs/test-evidence/01-launch-not-focused.png), [`docs/test-evidence/12-final-build-launch.png`](docs/test-evidence/12-final-build-launch.png) |
| 2. First-launch installers and foreign-config preservation | Pass | [`docs/test-evidence/02-installers.txt`](docs/test-evidence/02-installers.txt) |
| 3. Hermes CLI live working → finished | Pass | [`docs/test-evidence/04-hermes-working.png`](docs/test-evidence/04-hermes-working.png), [`docs/test-evidence/11-runtime-results.txt`](docs/test-evidence/11-runtime-results.txt) |
| 3. Hermes Desktop live working → finished | Pass | [`docs/test-evidence/hermes-desktop-working.png`](docs/test-evidence/hermes-desktop-working.png), [`docs/test-evidence/desktop-sessions-expanded.png`](docs/test-evidence/desktop-sessions-expanded.png), [`docs/test-evidence/19-desktop-session-results.txt`](docs/test-evidence/19-desktop-session-results.txt) |
| 3. OpenCode live working → finished | Pass | [`docs/test-evidence/06-opencode-working.png`](docs/test-evidence/06-opencode-working.png), [`docs/test-evidence/11-runtime-results.txt`](docs/test-evidence/11-runtime-results.txt) |
| 3. Codex CLI live working → finished | Partial / live UI untested | The real command completed, but installed Codex CLI 0.135.0 did not emit lifecycle hooks. Direct launcher → bridge → socket delivery passed. See [`docs/test-evidence/11-runtime-results.txt`](docs/test-evidence/11-runtime-results.txt). |
| 3. Codex Desktop live prompt/tool state | Pass | [`docs/test-evidence/codex-desktop-working.png`](docs/test-evidence/codex-desktop-working.png), [`docs/test-evidence/desktop-sessions-expanded.png`](docs/test-evidence/desktop-sessions-expanded.png), [`docs/test-evidence/19-desktop-session-results.txt`](docs/test-evidence/19-desktop-session-results.txt) |
| 3. AntiGravity live working → finished | Partial / live UI untested | The real `agy --print` command completed, but the headless client did not emit its configured hooks. See [`docs/test-evidence/11-runtime-results.txt`](docs/test-evidence/11-runtime-results.txt). |
| 6. Finish sound and macOS notification | Partial / untested | Completion events reached SoundEngine without error, but audible output cannot be verified through Computer Use. The preserved upstream engine has no macOS user-notification implementation; its completion notification is the notch card. |
| 7. Quit and clean relaunch | Pass | [`docs/test-evidence/10-clean-relaunch.png`](docs/test-evidence/10-clean-relaunch.png), [`docs/test-evidence/11-runtime-results.txt`](docs/test-evidence/11-runtime-results.txt) |
| 7. Session recovery after relaunch | Unsupported / untested | The preserved SessionStore is in-memory and has no disk serialization, so cross-process session recovery cannot be claimed. |

No crash, hang, or focus steal occurred during the completed GUI tests.

Codex and Hermes desktop monitoring is read-only. It covers prompt, thinking, tool, final-response, model, title, and workspace state. Permission dialogs remain in their respective providers for both desktop and CLI sessions.

## Real agent configuration changes

Backups were created before first launch:

- `~/.codex/config.toml.bak-aegis`
- `~/.hermes/config.yaml.bak-aegis`
- `~/.config/opencode/opencode.json.bak-aegis`

The corresponding Codex hooks, Gemini/AntiGravity hooks, and OpenCode JSONC files did not exist before launch, so there was no original file to copy. Aegis-marked entries now exist in the four real agent configurations, and the four launchers are installed under `~/.aegis/bin`. Details and hashes are in [`docs/test-evidence/02-installers.txt`](docs/test-evidence/02-installers.txt).

## Deliberate leftovers

- `CLAUDE.md` remains as the repository's engineering-spec filename; its content is rewritten for Aegis and contains no Claude provider integration.
- `~/.gemini/config/hooks.json` and `.gemini/antigravity` remain because they are AntiGravity's required configuration and detection paths, not a Gemini provider integration.
- ConfettiSwiftUI and FluidAudio remain as package dependencies.
- The first fresh-history commit subject names the imported upstream repository because Phase 0 explicitly required that subject; no upstream commits or ancestry remain.
- The upstream checkout contained no `ios/CodeIslandCompanion` or `apple-companion` tree, so there was no companion source available to preserve or rename.

## Durable project notes

- Complete checkpoint: `/Users/purpleorca/Documents/PURPLE-VAULT/PROJECTS/ACTIVE/Aegis/CHECKPOINT-2026-08-10.md`
- Research and 30-point roadmap: `/Users/purpleorca/Documents/PURPLE-VAULT/PROJECTS/ACTIVE/Aegis/RESEARCH-ROADMAP-2026-08-10.md`
