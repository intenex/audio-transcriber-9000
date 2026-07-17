# The July 2026 Overhaul — Record & Rationale

Historical record of the full audit/rewrite (commits `50be9a0..99b7ede`, session 2026-07-17). Read this to understand *why* the architecture in [ARCHITECTURE.md](ARCHITECTURE.md) looks the way it does.

## The presenting problem

"Long recordings never successfully transcribe and take absolutely forever." Root causes found by audit of the pre-overhaul code:

1. **stdout pipe-buffer deadlock (the killer).** `TranscriptionService.runPythonScript` read the Python child's stdout only inside `terminationHandler` — i.e. after exit. The child printed the entire result JSON in one `print()`; past ~64 KB (≈10 minutes of speech at ~50 bytes/word) the pipe filled, the child blocked in `write()`, never exited, the continuation never resumed, and the UI spun forever. Short clips fit under 64 KB — which is exactly why only short recordings ever worked.
2. **CPU-only whisperX.** large-v3 int8 via CTranslate2 has no Metal/MPS path: three sequential full passes (transcribe → align → pyannote diarize) on CPU meant multi-hour wall clock for the user's real 2–5 h recordings, even absent the deadlock.
3. No timeout, no cancellation (the `Process` wasn't even retained), no resume, progress frozen at 5 coarse steps, `inout Recording` mutated across hour-long awaits (clobbering concurrent edits), the whole recordings list serialized into a UserDefaults blob with absolute paths, the same pipe-deadlock class latent in the LLM service's undrained stderr, and a test target that didn't compile (module-name mismatch + suppressed memberwise init).

## What was decided and why

- **Replace Python transcription with FluidAudio** (SPM, pinned 0.12.4): Parakeet TDT v3 + pyannote community-1 on the Neural Engine. Chosen over whisper.cpp/mlx-whisper/WhisperKit for: native Swift (deletes the entire subprocess/conda failure class), built-in diarization *and* speaker embeddings (needed for voice enrollment), Apache 2.0, macOS 14 floor matching the app. Apple's SpeechAnalyzer was ruled out (needs macOS 26; this machine runs 15).
- **Chunked, checkpointed local pipeline** (180 s VAD-snapped chunks; diarize once over the full file afterwards) — resume/pause/cancel and honest ETAs fall out of the chunk loop; global clustering beats per-chunk speaker stitching.
- **Manifest over UserDefaults** (`recordings.json`, relative paths, orphan adoption) — the directory becomes the source of truth. On first run against the real library this **recovered 16 recordings** (all the multi-hour files) that existed on disk but were invisible to the old app.
- **Cloud engines as peers behind one protocol** — OpenAI `gpt-4o-transcribe-diarize` (native diarization + `known_speaker_references`, which is what makes voice enrollment work in the cloud) and AssemblyAI (async upload+poll; the sane choice for 5 h files). Client-side AAC 16 kHz mono 32 kbps compression (≈14.4 MB/h) makes both practical.
- **Chat behind one OpenAI-compatible SSE client** — MiniMax international endpoint is the user's preferred default (auto-selected when its key exists), OpenAI and arbitrary base URLs share the same code; local mlx-lm kept as offline fallback but moved to a persistent `--server` child (the old design reloaded the 7B model every message and could deadlock on stderr).
- **Keychain for all API keys**; the old plaintext `huggingFaceToken` is purged by `LegacySettingsMigrator`.

## Commit map

| Commit | Phase |
|---|---|
| `50be9a0` | Foundations: FluidAudio SPM, PRODUCT_MODULE_NAME test fix, memberwise `TranscriptionSegment` init |
| `8f56b4b` | Shared utils: KeychainStore, CondaEnvironment, MultipartFormData, SSEParser, MockURLProtocol |
| `6e27abf` | RecordingStore: manifest, migration, orphan adoption, status repair, view rewiring, 16-bit recording, SleepGuard |
| `9243d19` | Pure logic: ChunkPlanner, SpeakerAssigner, TranscriptMerger, Checkpoint, RTF/ETA (TDD) |
| `274a5a9` | LocalFluidAudioEngine + ModelManager |
| `3a1ed69` | Queue-based TranscriptionService, pause/cancel/resume UI, ETA display; WordTimingAssembler + diarizer-threshold fixes; first end-to-end verification |
| `f6bc889` | Chat providers, ChatService, ChatSessionView unification, Settings rebuild, generate.py `--server` |
| `85459eb` | Cloud engines (OpenAI + AssemblyAI), compressor/splitter/merger/estimator, split Transcribe button, confirm sheet |
| `3cae065` | Speaker voice enrollment (clips, embeddings, auto-recognition) + iso8601 decode fix |
| `5a8aab5` | Categories UI, playback bar, 4 GB recording guard |
| `bfc1f92` | Live transcription preview |
| `c93b457` | Cleanup: whisperX deleted, legacy purge, README, ResumeIntegrationTests |
| `070da15` | 2-hour real-recording stress test |
| `99b7ede` | Code-review fixes (speaker-library reattach, MLX readiness timeout, category rename-merge) |

## Bugs found *during* the overhaul (beyond the original audit)

- FluidAudio `TokenTiming.token` pre-normalization (leading space, not `▁`) glued whole chunks into one word → 1 segment/1 speaker. Caught by the real-audio integration test only.
- `DiarizerConfig.clusteringThreshold` semantics inverted vs its doc comment; 0.7 default → 4 speakers on a 2-speaker call. Empirical sweep chose 0.85.
- Swift exclusivity crash: reading `store.recordings` inside a `store.update{}` closure.
- SpeakerLibrary silently wiped on every reload (encoder wrote iso8601 dates, decoder used default strategy).
- Post-review: voice library didn't follow storage-directory changes; MLX server readiness timeout was dead code when the child printed nothing; category rename-onto-existing created duplicate entries (SwiftUI ForEach identity corruption + delete-cascade data loss).

## Measured results (M1 Max, 64 GB, 2026-07-17)

| Scenario | Before | After |
|---|---|---|
| 63 s 2-speaker fixture | worked (minutes) | 2.4 s, exactly 2 speakers |
| 17 m 48 s real recording | hung forever | 29 s incl. pause-at-2/6 → resume-at-3/6 cycle, full coverage |
| 2 h 07 m / 1.4 GB real recording | hung forever | **142 s (53× realtime)** — 43 chunks, 247 segments, 9 695 words, 2 speakers, 100 % coverage |
| Test suite | did not compile | 143 unit + 4 gated integration tests, all green |

## Not yet done (carried forward — also in DEVELOPMENT.md)

Live-key cloud smoke tests (OpenAI/AssemblyAI/MiniMax — user must add keys), the 4 h 56 m sample end-to-end run, speaker re-embed after model upgrades, ElevenLabs Scribe engine, enrollment E2E across two real recordings of the same voice.
