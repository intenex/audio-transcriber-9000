# Testing Guide

What exists, how to run it, and what "verified" means in this project. See [DEVELOPMENT.md](DEVELOPMENT.md) for the rules that these tests enforce.

## Test suites (Tests/AudioTranscriberTests/, `@testable import AudioTranscriber`)

**Unit — always run, no network, no models (171 tests as of 2026-07-17):**

| Suite | Covers |
|---|---|
| `TranscriptionLogicTests` | ChunkPlanner (snap/coverage/determinism), SpeakerAssigner (overlap/ties/nearest/normalize), TranscriptMerger (split rules, interpolation), TranscriptionCheckpoint (round-trip, resume skip, fingerprint discard), RTF/ETA math + formatter |
| `WordTimingAssemblerTests` | token→word assembly incl. the leading-space normalization gotcha |
| `RecordingStoreTests` | manifest round-trip, legacy UserDefaults migration, orphan adoption, crash-artifact skip, status repair, category rename-merge/delete cascades, sidecar deletion, tolerant status decode |
| `RecordingMetaTests` | `.meta.json` sidecar: written on insert/change (no-op updates leave the file byte-identical), **library reconstructs from the directory alone with stable UUIDs/names/categories** after deleting recordings.json, external (synced-in) meta edits win on reload, legacy-library backfill, delete cleanup |
| `TranscriptionQueueTests` | queue semantics with `MockTranscriptionEngine`: serial order, dedupe, pause keeps checkpoint → `.paused`, cancel deletes → `.pending`, failure → `.failed`, sidecar bytes written |
| `ChatProviderTests` / `ChatServiceSelectionTests` | SSE token streaming, system-prompt prepend, MiniMax `reasoning_content` + `base_resp` error on HTTP 200, 401/missing-key paths, undecodable-chunk tolerance; provider auto-selection (MiniMax→OpenAI→local, explicit wins) |
| `CloudEngineTests` | AudioSplitPlanner (25 MB math vs the real 4 h 56 m duration), PartMerger (offsets, canonical minting, enrolled-name propagation, S-token continuity), diarized_json + AssemblyAI response parsing, cost estimator, **mocked AssemblyAI end-to-end flow with real audio compression** |
| `SpeakerLibraryTests` | cosine math + thresholds, library round-trip (iso8601!), case-insensitive upsert, auto-match writes `.speakers.json` without overwriting user names, clip candidate selection rules |
| `SharedUtilsTests` | SSEParser (chunk boundaries, CRLF, multi-line data, [DONE]), MultipartFormData framing, KeychainStore round-trip (isolated service name) incl. **empty-set-is-no-op** (empty writes must never delete a stored key) |
| `KeychainFieldLiveTests` | In-process end-to-end for `KeychainSecureField`: mounts the real view in an NSWindow inside the hosted app, edits via the real field editor (paste = one-chunk insertText) → debounced Keychain save without Enter; emptying the field + focus loss must NOT delete the stored key. This exists because AX automation cannot focus SwiftUI SecureFields (see below) |
| `WindowedAudioLoaderTests` | resample length/energy on synthetic WAVs (48 k mono, 44.1 k stereo mixdown, 16 k passthrough), near-empty rejection, **equivalence with FluidAudio's loader on the real fixture** (length ±0.5 %, RMS ±10 %) |
| `RecordingFormatTests` / `CompressInPlaceTests` | format settings mapping (AAC caps at 48 k, never upsamples), **the exact recorder write path** (Float32 tap chunks → AAC AVAudioFile → playable m4a readable by WindowedAudioLoader, ~36 KB for 3 s), compress-in-place swap keeps sidecars + duration and skips already-compressed files |
| `ThinkTagFilterTests` / `SummaryParsingRobustnessTests` | `<think>` filtering incl. tags split across chunks, unclosed blocks, bare `<` passthrough; full summarize path with think-block + prose-wrapped JSON via mocked SSE |
| `LiveFixVerificationTests` (gated) | Exact bug repros on real data: the quirky 2 h WAV compresses fully (duration-matched — old AVAssetReader path truncated at ~150 s), and a live MiniMax-M3 summary on a real transcript (real Keychain key; think-block-free JSON) |
| `AudioRecorderTests` / `TranscriptionServiceTests` | model basics, formatter output, service initial state |

**Integration — gated by a marker file, uses real models (~1.5 GB, cached after first run):**

```bash
touch /tmp/audiotranscriber-integration-tests
xcodebuild -project AudioTranscriber9000.xcodeproj -scheme AudioTranscriber9000 test \
  -only-testing:AudioTranscriberTests/LocalEngineIntegrationTests \
  -only-testing:AudioTranscriberTests/ResumeIntegrationTests \
  -only-testing:AudioTranscriberTests/LongFileSmokeTests
rm /tmp/audiotranscriber-integration-tests
```

> Why a marker file: `TEST_RUNNER_`-prefixed env vars do **not** reach the hosted test bundle on this setup — don't waste time on that path again.

| Test | Proves | Baseline (M1 Max, 2026-07) |
|---|---|---|
| `LocalEngineIntegrationTests` | Full local pipeline on the repo's 63 s 2-speaker fixture (`test_recording.wav`): segments, **exactly 2 speakers**, monotonic word times, embeddings returned, RTF recorded | 2.4 s warm |
| `ResumeIntegrationTests` | Store+queue+real engine on a real 18-min recording: pause mid-ASR (2/6 chunks), **fresh service resumes at part 3/6**, full coverage, checkpoint cleaned | 29 s total incl. pause cycle |
| `LongFileSmokeTests` (2 h) | The real 2 h 07 m / 1.4 GB recording end-to-end (read-only on the source; checkpoint in temp): 43 chunks, 247 segments, 9 695 words, 2 speakers, 100 % coverage | 142 s (53×) |
| `LongFileSmokeTests` (5 h) | The real 4 h 56 m / **3.4 GB** recording — the file whose >2 GB payload crashed the old single-shot loader with error -40: 99 chunks, 544 segments, 100 % coverage via `WindowedAudioLoader` | 362 s (49×) |
| `DiarizerThresholdSweepTests` | Tuning harness: speaker count per clusteringThreshold on the fixture (0.85 ⇒ 2 ✓) | ~10 s |

Long real samples referenced by the integration tests live in `~/Documents/AudioTranscriber/` (tests `XCTSkip` when absent).

## Commands

```bash
# Everything unit (integration auto-skips without the marker):
xcodebuild -project AudioTranscriber9000.xcodeproj -scheme AudioTranscriber9000 -configuration Debug test
# Build only:
xcodebuild -project AudioTranscriber9000.xcodeproj -scheme AudioTranscriber9000 -configuration Debug build
```

Regenerate the project first if files changed: `xcodegen generate`.

## UI verification (osascript)

The app must be launched and probed before claiming UI work done:

```bash
open ~/Library/Developer/Xcode/DerivedData/AudioTranscriber9000-*/Build/Products/Debug/"Audio Transcriber 9000.app"
osascript -e 'tell application "System Events" to get name of every process whose name contains "Audio Transcriber"'
```

Hard-won accessibility notes:
- Sidebar outline path: `outline 1 of scroll area 1 of group 1 of splitter group 1 of group 1 of window 1`. Row 1 = search field, rows 3–5 = action buttons (New Recording / Import / Chat with All), section headers between, recordings follow. Select rows with `set selected of row N … to true` — `click` alone often doesn't update the SwiftUI selection.
- Settings tabs are toolbar buttons: `every button of toolbar 1` of the settings window (open with `keystroke "," using command down`). Expect: General, Transcription, AI Chat, Speakers, Storage.
- SwiftUI `Menu(primaryAction:)` (the split Transcribe button) is effectively **unclickable via the AX tree** — don't burn time on it; drive those flows with in-process integration tests instead (that's exactly why `ResumeIntegrationTests` exists).
- Many SwiftUI controls expose no `name`; probe `value` of static texts and `description` of buttons.

## Manual checklist for release-grade changes

- Record 30 s → live preview text appears → stop → auto-transcribe (if enabled) → transcript/summary tabs correct; `afinfo` shows 16-bit LE WAV.
- Queue 2+ recordings → serial processing, queue positions, pause → Resume, cancel → Pending.
- Force-quit mid-transcription → relaunch shows "Partially transcribed" → Resume completes with continuous timestamps.
- With real keys: one short + one >2 h recording via OpenAI (watch part splitting) and AssemblyAI; confirm cost sheet numbers are sane.
- Enrollment E2E: name a speaker with "Remember this voice" on recording A → transcribe recording B with the same voice → auto-named; Settings → Speakers shows the voice, ▶ plays the clip.
- Categories: create/move/rename-onto-existing (merges)/delete (falls back), collapse state survives relaunch.
- Storage dir switch: library swaps, voice enrollments follow (new SpeakerLibrary dir).
