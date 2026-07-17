# Development Guide — Rules, Best Practices, Gotchas

How to work on this codebase without regressing it. Read [ARCHITECTURE.md](ARCHITECTURE.md) first; verification lives in [TESTING.md](TESTING.md).

## Workflow rules

1. **`xcodegen generate` after adding/removing/moving any source file** (or editing `project.yml`). The `.xcodeproj` is generated; never hand-edit it. Build failures like "Build input file cannot be found" mean you forgot this.
2. **Commit small and green.** One logical step per commit; build + `xcodebuild test` must pass before each commit. This repo's history is the template — follow it.
3. **TDD the pure logic.** Anything computable without models/network/UI (planners, mergers, parsers, stores, math) gets unit tests written with or before the implementation. Pure logic lives in `enum`/`struct` helpers precisely so it's testable — keep it that way when adding features.
4. **Verify end-to-end before claiming done.** Unit tests are necessary, not sufficient. Use the gated integration tests (marker file — see TESTING.md) and launch the app. Two bugs in the overhaul (token gluing, diarizer over-splitting) passed every unit test and only surfaced on real audio.
5. **Session end**: run the mandatory checklist in CLAUDE.md / AGENTS.md (build, tests, launch + osascript verification, honest report).

## Invariants — do not break these

- **Sidecar formats are frozen** (`.md`, `.segments.json`, `.speakers.json`, `.summary.json`, `.chat.json`). Pre-overhaul files must keep loading. If you must evolve one, decode-with-fallback (see `TranscriptionSegment.init(from:)` tolerating missing `words`). New sidecar? Add it to `Recording.allSidecarURLs` or deletion will leak it.
- **`TranscriptionEngine` contract** (ARCHITECTURE.md): normalized `SPEAKER_%02d` labels, Task-cancellation honored, checkpoint resume, monotonic progress. The queue, UI, speaker library, and formatter all assume it.
- **Checkpoint chunk plans are immutable on resume.** Never recompute the plan for an existing checkpoint — VAD nondeterminism or config drift would misalign completed chunks. Changing checkpoint semantics ⇒ bump `TranscriptionCheckpoint.currentVersion` (old checkpoints are then discarded, which is safe).
- **`TranscriptionStatus` decoding is tolerant** (unknown → `.pending`). Keep it that way; old manifests must never fail to load. Every `switch` over the enum is exhaustive — the compiler walks you through new cases.
- **Secrets go in Keychain**, never UserDefaults. New key ⇒ add a `SecretKey` case. New UserDefaults key ⇒ add it to the inventory in ARCHITECTURE.md.
- **recordings.json is authoritative but self-healing** — code must survive a deleted/corrupt manifest (orphan adoption rebuilds it). Don't add state that can't be reconstructed or tolerated as lost.

## Concurrency rules (violations here were real crashes)

- **Swift exclusivity with @Observable stores**: never call anything that *reads* `store.recordings` (e.g. `store.recording(with:)`, `statusForExistingCheckpoint`) from **inside** a `store.update { }` closure — `update` holds exclusive `inout` access to the array and you get a runtime "Fatal access conflict". Compute values before the closure.
- **Never block the cooperative pool.** Synchronous heavy calls (e.g. `performCompleteDiarization`) go through `withCheckedThrowingContinuation` + `DispatchQueue.global`. 
- **Every `Process` must have both pipes drained continuously** (readabilityHandler or equivalent) — a full 64 KB pipe deadlocks the child forever. This exact bug was why long transcriptions never finished pre-overhaul, and it existed a second time in the old LLM service's stderr. Also: retain the `Process`/`Task` so it can be cancelled, and wire `continuation.onTermination` to kill children.
- **Timeouts must not depend on receiving data.** Waiting loops poll a buffer + deadline (see `MLXServerProcess.waitForReady`) rather than `for await` alone — a silent child means no chunks means a dead deadline check.
- **AVAudioEngine**: hardware init off the main thread (TCC deadlock); no format conversion inside the tap callback (historic `ExtAudioFile::WriteInputProc` crash) — the `AVAudioFile(… commonFormat:)` trick converts internally instead; don't reuse an `AsyncStream` across cancelled iterations (single-consumption; cancellation finishes the continuation).
- **Large-file reads**: a single `AVAudioFile.read`/`ExtAudioFileRead` fails with coreaudio **error -40** once the requested payload exceeds ~2 GB (internal 32-bit overflow) — any recording over ~3 h of Float32/48 kHz. Always read in windows; use `WindowedAudioLoader` (persistent AVAudioConverter across windows, so no resampler seams).
- **NSViewRepresentable coordinators outlive selection changes.** SwiftUI reuses the NSView + Coordinator when the detail view switches records — any closure or content captured at `makeCoordinator`/`makeNSView` time goes stale. Re-assign closures in `updateNSView` and key content rebuilds on an explicit `contentID`, not on data shape (two recordings can have identical segment counts). This exact bug made transcript clicks play the previously viewed recording.

## FluidAudio gotchas (pinned `exactVersion: 0.12.4` — re-verify all of these on upgrade)

- `TokenTiming.token` is **pre-normalized**: SentencePiece `▁` already replaced with a **leading space**. Word assembly splits on `hasPrefix(" ")` (`WordTimingAssembler`). Splitting on `▁` glues an entire chunk into one giant "word", which cascades into 1 segment / 1 speaker.
- `DiarizerConfig.clusteringThreshold`: **higher = more merging = fewer speakers** — the library's doc comment implies the opposite. App default **0.85** (UserDefaults `diarizationClusteringThreshold`); library default 0.7 split a real 2-speaker phone call into 4. Tuning harness: `DiarizerThresholdSweepTests`.
- `DiarizerModels` is `consuming` on `initialize` — you can't reuse the models value; reload via `downloadIfNeeded()` (disk-cached, fast) when rebuilding the manager.
- Model caches: `AsrModels.defaultCacheDirectory()`, `DiarizerModels.defaultModelsDirectory()` (~1.5 GB total). First *build* needs network once (binary xcframework dependency).
- Measured baselines on this M1 Max (update if hardware changes): 63 s file ≈ 2.4 s warm; 2 h 07 m file ≈ 142 s (53×); diarization included.

## Recipes

**Add a transcription engine**: new `TranscriptionEngineKind` case → implement `TranscriptionEngine` (normalize speakers, honor cancellation, map provider errors to `CloudTranscriptionError`) → register in `AudioTranscriberApp`'s `cloudEngineFactory` → add `SecretKey` + Settings field (`KeychainSecureField`) → cost constant in `TranscriptionCostEstimator` → menu entries in `TranscriptionView.transcribeMenuItems` + `RecordingListView.rowContextMenu` → mocked-flow unit test (MockURLProtocol; see `AssemblyAIEngineFlowTests`).

**Add a chat provider**: if it's OpenAI-compatible, just instantiate `OpenAICompatibleChatProvider` in `ChatService` with base URL/model/key closures + Settings section + `ChatProviderID` case. Anything else implements `ChatProvider` directly (stream events, respect `contextCharacterBudget`).

**Add a sidecar file**: helper URL on `Recording`, append to `allSidecarURLs`, decide load/save owner, add round-trip test.

**Touch the UI shell**: keep `TranscriptionView` state switches exhaustive; anything status-related must handle `.paused`/`.partial`; new environment objects must be injected in **both** scenes in `AudioTranscriberApp`.

## Known limitations / future work

- Cloud engines are verified against mocked HTTP only — live-key smoke tests still pending (needs user's keys; run one short + one long recording through OpenAI and AssemblyAI when keys exist).
- OpenAI multi-part uploads: >4 concurrently-present speakers can fragment identity across parts (reference cap is 4) — accepted; pills rename merges.
- Attribution: cloud transcription attribution is engine-level (`modelDescription`); AssemblyAI doesn't expose a finer model name in responses we parse.
- Speaker library "re-embed from clips" (after a FluidAudio model upgrade) is not implemented — enrollments would need re-creating from source recordings.
- ElevenLabs Scribe is the natural third cloud engine if wanted (follow the engine recipe).
- `AudioRecorder`'s tap-local `firstWriteError` capture is technically an unsynchronized cross-thread read (benign in practice with the 300 ms margin) — tidy if you're in there anyway.
