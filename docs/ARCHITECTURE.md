# Architecture

Current-state system map. Companion docs: [DEVELOPMENT.md](DEVELOPMENT.md) (rules & gotchas), [TESTING.md](TESTING.md) (verification), [HISTORY-2026-07-OVERHAUL.md](HISTORY-2026-07-OVERHAUL.md) (why things are this way).

## System overview

SwiftUI + `@Observable` (Observation framework, not ObservableObject), macOS 14+, Apple Silicon only. **Not sandboxed** (subprocess + arbitrary storage-dir access); hardened runtime on; ad-hoc signed. Transcription is 100% native Swift via the FluidAudio SPM package — Python/conda exists **only** for the optional local mlx-lm chat provider.

```
AudioTranscriberApp (wiring, env injection)
├── RecordingStore          library manifest, categories, import/delete, migration
├── AudioRecorder            record (AVAudioEngine tap) + playback; feeds LiveTranscriber
├── TranscriptionService     serial job queue → TranscriptionEngine implementations
│     ├── LocalFluidAudioEngine     (actor) Parakeet v3 ASR + pyannote diarization, chunked + checkpointed
│     ├── OpenAITranscriptionEngine  gpt-4o-transcribe-diarize, compression + part splitting
│     └── AssemblyAITranscriptionEngine  compress → upload → poll
├── ChatService              provider registry → ChatProvider implementations
│     ├── OpenAICompatibleChatProvider ×3  (MiniMax intl / OpenAI / custom base URL, SSE)
│     └── LocalMLXChatProvider          persistent `generate.py --server` child (actor MLXServerProcess)
├── SpeakerLibraryStore      voice enrollment: embeddings + reference clips, auto-matching
├── ModelManager             on-disk speech-model status / download / remove
├── LiveTranscriber          streaming preview while recording (FluidAudio StreamingAsrManager)
└── SleepGuard               ProcessInfo activity assertion during record/transcribe
```

### App wiring order (AudioTranscriberApp.onAppear — order matters)

1. `LegacySettingsMigrator.runOnce()` — purges plaintext `huggingFaceToken`/`whisperModel`
2. `recordingStore.load()` — manifest → legacy migration → orphan adoption → status repair
3. `speakerLibrary.attach(storageDirectory: recordingStore.storageDirectory)`
4. `audioRecorder.attach(store:)`, `audioRecorder.liveTranscriber = liveTranscriber`
5. `transcriptionService.attach(store:chatService:speakerLibrary:)` + `cloudEngineFactory`
6. `audioRecorder.onNewRecording` → auto-transcribe hook (UserDefaults `autoTranscribeNewRecordings`)

Both the WindowGroup **and the Settings scene** get every service injected — the Settings scene crashing from a missing environment object was a real pre-overhaul bug class.

## TranscriptionEngine contract (`Services/Transcription/TranscriptionEngine.swift`)

```swift
protocol TranscriptionEngine: Sendable {
    var id: String { get }              // stable; used as the RTF-calibration key
    var kind: TranscriptionEngineKind { get }   // .local / .openAI / .assemblyAI
    func prepare(progress:) async throws        // idempotent; may download models
    func transcribe(_ request: TranscriptionRequest, progress:) async throws -> TranscriptionOutput
}
```

Invariants every engine MUST uphold:
- **Speaker IDs normalized** to `SPEAKER_00`-style strings in first-appearance order (all downstream UI — MarkdownFormatter, speaker pills, `.speakers.json` — depends on this).
- **Honor structured Task cancellation** (`try Task.checkCancellation()` between units of work; throw `CancellationError`). The service maps cancellation → pause/cancel intent.
- **Resume from a valid checkpoint** at `request.checkpointURL` when one exists (local engine); cloud engines simply don't checkpoint.
- Progress via the `@Sendable` closure; `fractionComplete` monotonic 0…1; optional `etaSeconds`.
- `TranscriptionOutput` = existing `TranscriptionResult` (segments/language/numSpeakers) + `speakerNames` (auto-identified, e.g. from enrolled references) + `speakerEmbeddings` (local engine only, keyed by normalized ID, consumed by SpeakerLibraryStore matching).

## Local pipeline (`LocalFluidAudioEngine`, actor — models stay loaded across jobs)

1. `AudioConverter().resampleAudioFile(url)` → 16 kHz mono Float32 (whole file in RAM; 5 h ≈ 1.15 GB — fine on this machine).
2. **Chunk plan**: `ChunkPlanner.plan` — 180 s targets, boundaries snapped to the midpoint of the nearest VAD silence gap within ±30 s (Silero VAD via `VadManager.segmentSpeech`; VAD failure degrades to hard cuts). The plan is **persisted in the checkpoint and reused verbatim on resume** — never recomputed.
3. **Per-chunk serial loop** with `Task.checkCancellation()`: slice samples → `AsrManager.transcribe(_, source: .system)` → word timings via `WordTimingAssembler` (token timings; interpolation fallback when absent) offset to absolute time → `checkpoint.record` + atomic save of `<stem>.partial.json` → `RTFStore.record` → progress+ETA callback. Cancel/checkpoint granularity ≈ 2 s wall.
4. **Diarization**: one full-file `DiarizerManager.performCompleteDiarization` pass after ASR (global clustering ≫ per-chunk accuracy). It's synchronous & heavy → dispatched to a GCD queue so it can't starve the Swift-concurrency cooperative pool. `checkpoint.asrComplete = true` beforehand, so a kill during diarization only re-runs diarization.
5. `SpeakerAssigner` (whisperX `assign_word_speakers` port: max temporal overlap, ties → earlier turn, zero overlap → nearest midpoint, O(n+m)) → `normalizeSpeakerIDs` → `TranscriptMerger.makeSegments` (splits on speaker change / gap >0.8 s / sentence punctuation + gap >0.3 s / 30 s cap).
6. Cluster embeddings keyed by normalized IDs go into `TranscriptionOutput.speakerEmbeddings`.

**Checkpoint schema** (`TranscriptionCheckpoint`, version 1): `{version, engineID, recordingID, audioFingerprint{fileSizeBytes,durationSeconds}, createdAt, updatedAt, chunkPlan[], chunks[{index,text,words[],processingSeconds}], asrComplete}`. `loadIfValid` rejects (and deletes) on version/engineID/fingerprint mismatch (duration tolerance 1 s).

**ETA**: `RTFStore` persists per-engine realtime factors in UserDefaults (`rtf.<engineID>`, EMA α = 0.3; conservative defaults 20× ASR / 50× diarizer). `ETACalculator` = remaining ASR audio ÷ asrRTF + (diarization pending ? total ÷ diarizerRTF : 0). `ETAFormatter` renders "~3 min remaining".

**Diarizer tuning**: `DiarizerConfig.clusteringThreshold` — **higher = more merging = fewer speakers** (doc comment in the library implies the opposite; verified empirically). App default **0.85** (`LocalFluidAudioEngine.defaultClusteringThreshold`, override via UserDefaults `diarizationClusteringThreshold`); the library's 0.7 default over-split a real 2-speaker call into 4. Changing the value rebuilds the diarizer on next `prepare()`.

## Queue orchestrator (`TranscriptionService`, @Observable @MainActor)

- Serial FIFO of `(recordingID, engineKind)`; one worker task; the in-flight job's `Task` is retained for cancellation.
- API: `enqueue(_:using:)` (dedupes; sets status `.processing` immediately so the UI shows queue position), `pause(_:)` (cancel task, checkpoint kept → `.paused`), `cancel(_:)` (checkpoint deleted → `.pending`); resume = enqueue again.
- Stop intent is recorded in `stopIntents` **before** `jobTask.cancel()` so wrapped cancellation errors still resolve to the right status.
- On success: writes `.md` (MarkdownFormatter — format unchanged since pre-overhaul) + `.segments.json`, merges `output.speakerNames` into `.speakers.json` **without overwriting user-set names**, calls `speakerLibrary.handleTranscriptionCompleted` (embedding matching), deletes the checkpoint, status → `.done`, posts a UNUserNotification when the app is inactive, fire-and-forgets auto-summarize via `chatService.activeProvider` (UserDefaults `autoSummarize`, default on).
- `SleepGuard` held while the queue drains. Notifications suppressed under XCTest.
- `TranscriptionStatus` cases: `pending / processing / done / failed / paused / partial`; unknown raw values decode to `.pending`. Launch repair (in RecordingStore.load): persisted `.processing` → `.partial` if a checkpoint exists else `.pending`.
- Test hooks: `engineOverride` (forces one engine for all kinds), `cloudEngineFactory` closure for cloud engines.

## Cloud engines (`Services/Providers/Transcription/`)

Shared: `AudioCompressor` (AVAssetReader→AVAssetWriter; AAC 16 kHz mono 32 kbps ≈ **14.4 MB/hour**; supports `CMTimeRange` slicing — also used for reference-clip extraction), `CloudAudioSpec` constants, typed `CloudTranscriptionError`, cost estimates in `TranscriptionCostEstimator` (list-price constants — update when providers reprice).

**OpenAI** (`gpt-4o-transcribe-diarize`, multipart to `/v1/audio/transcriptions`): `response_format=diarized_json`, `chunking_strategy=auto`, up to 4 `known_speaker_names[]`/`known_speaker_references[]` (data:audio/mp4;base64 clips ≤10 s) from the voice library — enrolled speakers come back already named. Files >25 MB after compression (≈ >1 h45 m audio) are split by `AudioSplitPlanner` into equal parts under limit×0.88; parts upload sequentially; **speaker continuity** across parts: next part's references = confirmed enrolled speakers ∪ clips extracted from prior parts' speakers (longest ≥3 s segment, named with stable `S1`/`S2` tokens); `PartMerger` offsets times and maps labels → canonical `SPEAKER_%02d`. Retries 429/5xx twice (2 s/8 s backoff); 401/413 fail fast. Response segments carry no word timings (`words: []` — the interactive transcript UI tolerates this and interpolates).

**AssemblyAI**: compress (turns a 3 GB WAV into ~70 MB) → `POST /v2/upload` (raw body, `authorization` header, `upload(fromFile:)` so nothing large is held in memory) → `POST /v2/transcript` `{audio_url, speaker_labels, language_detection}` → poll `GET /v2/transcript/{id}` every 3 s, cancellation-aware. Maps `utterances[]`/`words[]` (ms → s) with word-level speakers; letters `A`/`B` normalized to `SPEAKER_%02d`. No client splitting ever (5 GB cap). No known-speaker support → library matching is skipped for this engine.

## Chat layer (`Services/Providers/Chat/`)

- `ChatProvider` protocol: `streamChat(messages:system:) -> AsyncThrowingStream<ChatStreamEvent, Error>` (`.token` / `.reasoning`), `contextCharacterBudget` (local 6 k, cloud 100 k — consumers truncate context with it), `isConfigured`. Default `generate()` accumulates tokens.
- `OpenAICompatibleChatProvider` — one class, three instantiations (base URL/model/key via closures so Settings edits apply live):
  - MiniMax: `https://api.minimax.io/v1` (international), default model `MiniMax-M2` (UserDefaults `miniMaxModel`)
  - OpenAI: `https://api.openai.com/v1`, default `gpt-4o-mini` (`openAIChatModel`)
  - Custom: base URL `customChatBaseURL`, model `customChatModel`, key `.custom`
  SSE via `URLSession.bytes` + chunk-boundary-safe `SSEParser`. MiniMax quirks handled: `reasoning_content` deltas → `.reasoning` (UI shows "Thinking…"), `base_resp.status_code != 0` on HTTP 200 → error, undecodable chunks skipped. Timeouts 30 s request / 600 s resource.
- `LocalMLXChatProvider` + `MLXServerProcess` (actor): persistent `generate.py --server` child — model loads once and stays warm. Line protocol: one JSON request per stdin line; child streams tokens to stdout and terminates each response with sentinel `\x1E<<END:ok>>` / `\x1E<<END:err:…>>`; readiness = `\x1E<<READY>>`. Stdout is drained into an actor buffer by the readability handler and consumers **poll** it — so timeouts fire even if the child never prints (stalled model download). Stderr always drained. Cancellation terminates the child; next request restarts it.
- `ChatService` (@Observable @MainActor): explicit user selection (`chatProviderID`) wins; otherwise auto: **MiniMax if keyed → OpenAI if keyed → local MLX**. `isActiveProviderReady` gates the chat UI.
- `ChatSessionView(context: .recording(r) | .global)` — single implementation for both chats; error bubble with Retry; interrupted streams kept and marked; per-recording history in `.chat.json`, global in `.global-chat.json`.

## Speaker voice library (`Services/SpeakerLibrary/`)

- `SpeakerLibraryStore` — `<storageDir>/SpeakerLibrary/library.json` (version, `autoMatchThreshold` default 0.70, speakers with `embeddings: [[Float]]`, clips, `recordingIDs`) + m4a clips under `clips/<uuid>/`. ISO8601 dates on **both** encode and decode (a mismatch here once silently wiped the library). Upsert by case-insensitive name enriches an existing speaker. **Must be re-`attach`ed when the storage directory changes** (StorageSettingsTab does this).
- Enrollment flow (TranscriptionView rename popover, "Remember this voice" default on): `ReferenceClipExtractor.selectCandidates` (clean non-overlapping segments ≥3 s, middle-10 s trim, 8–15 s total, max 3) → 16 kHz samples → `LocalFluidAudioEngine.extractEmbedding` (requires models; skips silently if absent) → clips via `AudioCompressor` → `enroll`.
- Matching: after each local transcription, cluster embeddings vs library via `SpeakerMatcher` (vDSP cosine, best-of-multiple-embeddings, threshold slider 0.50–0.90 in Settings → Speakers). Writes into `.speakers.json` only for keys the user hasn't set. Cloud: `referenceCandidates(limit: 4)` ranked by recordings-seen then recency feed OpenAI's known-speaker fields.

## Persistence

**`RecordingStore`** (@Observable @MainActor) owns `recordings` + `categories`, persisted to `<storageDir>/recordings.json` (schemaVersion 1, entries with **relative** `fileName` for in-dir files / `absolutePath` otherwise). Load order: manifest → else one-time migration from UserDefaults key `"recordings"` (legacy key left as rollback backup; the manifest's existence is the migration marker) → drop entries with missing audio → **orphan adoption** (any untracked audio file in the dir becomes a Recording; `.md` present ⇒ `.done`; ≤4096-byte crash artifacts skipped) → status repair. Saves are debounced 500 ms + `saveNow()` on `willTerminateNotification`. **The directory is the source of truth** — a lost manifest self-heals. Category rename cascades into recordings; renaming onto an existing name **merges** (no duplicate entries); delete falls back to Uncategorized.

**Sidecars** (beside each audio file; formats unchanged from pre-overhaul — keep backward compatible):
| File | Contents | Writer |
|---|---|---|
| `<stem>.md` | Markdown transcript | TranscriptionService (MarkdownFormatter) |
| `<stem>.segments.json` | `[TranscriptionSegment]` word-level | TranscriptionService |
| `<stem>.speakers.json` | `[String: String]` id → display name | TranscriptionView pills + auto-match |
| `<stem>.summary.json` | RecordingSummary | SummarizationService |
| `<stem>.chat.json` | ChatHistory | ChatSessionView |
| `<stem>.partial.json` | TranscriptionCheckpoint (deleted on success) | LocalFluidAudioEngine |
`Recording.allSidecarURLs` is the single deletion list — extend it when adding a sidecar.

**Secrets**: Keychain only (`KeychainStore`, kSecClassGenericPassword, service = bundle id; `SecretKey`: `openai.apiKey`, `minimax.apiKey`, `assemblyai.apiKey`, `custom.apiKey`). `InMemorySecretsStore` for tests. Never mirror secrets into UserDefaults.

**UserDefaults inventory** (add new keys to this list): `storageDirectory`, `llmModel`, `recordings` (legacy backup only), `defaultTranscriptionEngine`, `confirmCloudTranscription`, `autoSummarize`, `autoTranscribeNewRecordings`, `liveTranscriptionPreview`, `chatProviderID`, `miniMaxModel`, `openAIChatModel`, `customChatBaseURL`, `customChatModel`, `diarizationClusteringThreshold`, `playbackRate`, `collapsedCategories`, `rtf.<engineID>`, `didCleanupLegacyKeys.v1`.

## Recording & playback (`AudioRecorder`)

- AVAudioEngine input tap in the **native input format** (never convert in the tap callback — historic EXC_BREAKPOINT crash). File is 16-bit PCM WAV at native rate via `AVAudioFile(forWriting:settings:commonFormat:.pcmFormatFloat32:interleaved:false)` — the `commonFormat:` pins `processingFormat` to the tap's Float32 so ExtAudioFile converts internally (≈346 MB/hour, half of Float32). Guarded fallback to native-format settings if the tap isn't Float32. First-write errors surface within ~300 ms instead of producing a 4 KB dead file.
- Hardware init runs off the main thread (`Task.detached`) — `inputNode` access deadlocks on the main thread via coreaudiod TCC.
- Duration: wall-clock display during recording; authoritative final = `file.length / processingFormat.sampleRate`. Auto-stop at 3.9 GB (WAV 4 GB header cap).
- Playback: AVAudioPlayer with `enableRate`; `playbackRate` persisted; `seek/seekAndPlay` drive the interactive transcript's word highlighting via a 0.05 s timer updating `playbackTime`.
- Tap also feeds `LiveTranscriber` (StreamingAsrManager, `.streaming` config; accepts any buffer format; preview-only, discarded at stop; never downloads models mid-recording).

## Views

`ContentView` (NavigationSplitView) → `RecordingListView` (search, collapsible category sections, context menus, engine submenu) | detail: `RecordingControlView` (record + live preview) / `TranscriptionView` (header + playback bar + tabs Transcript/Summary/Chat, split Transcribe button with per-engine costs, `CloudTranscribeConfirmSheet`, active/queued/paused/failed states with ETA + Pause/Cancel, speaker pills + enrollment popover, export menu) / `ChatSessionView` (.global). `InteractiveTranscriptView` = NSViewRepresentable NSTextView: word-click seeks audio, playback word highlighting (yellow background), search highlighting (orange underline — deliberately a different attribute so they don't clobber each other). `SettingsView` tabs: General / Transcription / AI Chat / Speakers / Storage.
