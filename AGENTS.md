<!--
  MIRRORED FILE: CLAUDE.md and AGENTS.md are byte-identical twins.
  When you change one, copy it over the other in the same commit:
      cp CLAUDE.md AGENTS.md   (or the reverse)
  A drift between them is a bug.
-->

# Audio Transcriber 9000 — Agent Instructions

Native macOS (14+, Apple Silicon) SwiftUI app: recording, on-device transcription with speaker diarization (FluidAudio / Neural Engine), resumable transcription queue, optional cloud engines (OpenAI, AssemblyAI), multi-provider AI chat (MiniMax default-when-keyed), speaker voice enrollment, categories.

## Required reading (in this order, before non-trivial changes)

| Doc | What it gives you |
|---|---|
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Full system map: engines, queue, stores, chat providers, speaker library, data formats, UserDefaults/Keychain inventories |
| [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) | Workflow rules, hard invariants, concurrency rules, FluidAudio/AVFoundation gotchas, recipes for adding engines/providers/sidecars, known limitations |
| [docs/TESTING.md](docs/TESTING.md) | Every test suite, the integration-test marker-file gate, measured performance baselines, osascript UI recipes, manual checklists |
| [docs/HISTORY-2026-07-OVERHAUL.md](docs/HISTORY-2026-07-OVERHAUL.md) | Why the architecture is this way: root causes, decisions, commit map, bugs found, before/after numbers |

Keep these docs **current**: any change that alters architecture, invariants, test baselines, or adds settings/sidecars must update the matching doc in the same commit.

## Non-negotiable rules (details and rationale in docs/DEVELOPMENT.md)

1. `xcodegen generate` after adding/removing/moving source files — the `.xcodeproj` is generated, never hand-edited.
2. Commit small and green: build + full `xcodebuild test` pass before every commit; one logical step per commit.
3. Sidecar file formats (`.md`, `.segments.json`, `.speakers.json`, `.summary.json`, `.chat.json`) are frozen/backward-compatible; new sidecars must join `Recording.allSidecarURLs`.
4. Uphold the `TranscriptionEngine` contract: `SPEAKER_%02d` normalization, Task-cancellation honored, checkpoint resume, monotonic progress. Never recompute an existing checkpoint's chunk plan.
5. Secrets → Keychain (`SecretKey`), never UserDefaults. New UserDefaults keys join the inventory in docs/ARCHITECTURE.md.
6. Concurrency: never read an `@Observable` store inside its own `update {}` closure (exclusivity crash); drain **both** pipes of every `Process`; heavy sync work off the cooperative pool; timeouts must fire without incoming data.
7. Pure logic gets unit tests (TDD); anything touching real audio/models gets verified via the gated integration tests — unit-green alone proved insufficient twice (see HISTORY doc).

## Before Ending Any Session — MANDATORY

1. **Plan check** — if the session has an active plan file, verify every item is implemented; continue if items remain doable.
2. **Build** — `xcodebuild -project AudioTranscriber9000.xcodeproj -scheme AudioTranscriber9000 -configuration Debug build` → `BUILD SUCCEEDED`.
3. **Unit tests** — `xcodebuild -project AudioTranscriber9000.xcodeproj -scheme AudioTranscriber9000 test` → all green (integration tests auto-skip without the marker file).
4. **Integration tests when the transcription pipeline was touched** — `touch /tmp/audiotranscriber-integration-tests`, run the suites named in docs/TESTING.md, then remove the marker.
5. **Launch and probe the app** —
   - `open ~/Library/Developer/Xcode/DerivedData/AudioTranscriber9000-*/Build/Products/Debug/"Audio Transcriber 9000.app"`
   - Verify via `osascript` (recipes + AX-tree quirks in docs/TESTING.md): process running, sidebar populated, features you modified actually work. Quit cleanly.
6. **Report honestly** — what was completed, what was tested and how, what remains (with reasons). Never claim "everything works" without having run the verification.

## Project facts

- Bundle ID: `com.audiortranscriber.AudioTranscriber`; process name "Audio Transcriber 9000"
- Build product: `~/Library/Developer/Xcode/DerivedData/AudioTranscriber9000-*/Build/Products/Debug/Audio Transcriber 9000.app`
- Test module: `@testable import AudioTranscriber` (PRODUCT_MODULE_NAME override; product name contains spaces)
- FluidAudio pinned `exactVersion: 0.12.4` in project.yml — re-verify the gotchas in docs/DEVELOPMENT.md on any upgrade; first build after a clean checkout needs network (binary xcframework)
- Transcription is native Swift. conda env `transcriber` is used **only** by the optional local mlx-lm chat provider (`scripts/generate.py`)
- Mic access needs a manual grant in System Settings → Privacy → Microphone (TCC; ad-hoc signing makes programmatic TCC edits useless)
- User library: `~/Documents/AudioTranscriber` (configurable) — real recordings up to ~5 h live there and are used by the gated integration tests; treat as user data (read-only unless the flow explicitly writes sidecars)
