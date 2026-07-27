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

Engines also expose `modelDescription` (e.g. "On-Device · Parakeet v3 + pyannote") — written to `Recording.engineUsed` and the markdown header on completion, so every transcript records what produced it.

Invariants every engine MUST uphold:
- **Speaker IDs normalized** to `SPEAKER_00`-style strings in first-appearance order (all downstream UI — MarkdownFormatter, speaker pills, `.speakers.json` — depends on this).
- **Honor structured Task cancellation** (`try Task.checkCancellation()` between units of work; throw `CancellationError`). The service maps cancellation → pause/cancel intent.
- **Resume from a valid checkpoint** at `request.checkpointURL` when one exists (local engine); cloud engines simply don't checkpoint.
- Progress via the `@Sendable` closure; `fractionComplete` monotonic 0…1; optional `etaSeconds`.
- `TranscriptionOutput` = existing `TranscriptionResult` (segments/language/numSpeakers) + `speakerNames` (auto-identified, e.g. from enrolled references) + `speakerEmbeddings` (local engine only, keyed by normalized ID, consumed by SpeakerLibraryStore matching).

## Local pipeline (`LocalFluidAudioEngine`, actor — models stay loaded across jobs)

1. `WindowedAudioLoader.load16kMono(from:)` → 16 kHz mono Float32 (whole result in RAM; 5 h ≈ 1.15 GB — fine). Windowed 60 s reads through **one persistent AVAudioConverter** — a single whole-file read (what FluidAudio's `resampleAudioFile` does) fails with coreaudio **error -40** once the PCM payload exceeds ~2 GB (≈3 h of Float32/48 kHz). Tolerates mid-file read errors from truncated headers (transcribes what exists).
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
- `TranscriptionStatus` cases: `pending / processing / done / failed / paused / partial`; unknown raw values decode to `.pending`. Launch repair (in RecordingStore.load): a checkpoint on disk wins (`.processing` → `.partial`); with **no** checkpoint, an existing `.md` wins (`.processing`/`.partial`/`.paused` → `.done` — never demote a finished recording); otherwise `.pending`.
- **Auto-retry**: transient engine failures (ANE inference hiccups on hour-plus jobs) are retried up to 3 attempts with a 2 s backoff (`retryDelaySeconds` test hook), resuming from the chunk checkpoint so completed work is never redone; a pause/cancel during backoff wins. After the final attempt the error text is persisted to `Recording.lastError` (manifest cache only, never the synced `.meta.json`) and shown in `FailedTranscriptionView`; cleared on enqueue/success. Full error detail is NSLogged for `log show` forensics.
- Test hooks: `engineOverride` (forces one engine for all kinds), `retryDelaySeconds`, `cloudEngineFactory` closure for cloud engines.

## Cloud engines (`Services/Providers/Transcription/`)

Shared: `AudioCompressor` — windowed **AVAudioFile** reads + persistent AVAudioConverter + AVAudioFile AAC writes (NOT AVAssetReader, which truncates some older WAVs — see DEVELOPMENT.md). Specs: `.cloudUpload` (16 kHz mono 32 kbps ≈ 14.4 MB/h), `.storage` (48 kHz mono 96 kbps), `.storageCompact` (48 kbps); `CMTimeRange` slicing for clips/parts; optional progress callback. Plus `CloudAudioSpec` constants, typed `CloudTranscriptionError`, cost estimates in `TranscriptionCostEstimator` (list-price constants — update when providers reprice).

**OpenAI** (`gpt-4o-transcribe-diarize`, multipart to `/v1/audio/transcriptions`): `response_format=diarized_json`, `chunking_strategy=auto`, up to 4 `known_speaker_names[]`/`known_speaker_references[]` (data:audio/mp4;base64 clips ≤10 s) from the voice library — enrolled speakers come back already named. Files >25 MB after compression (≈ >1 h45 m audio) are split by `AudioSplitPlanner` into equal parts under limit×0.88; parts upload sequentially; **speaker continuity** across parts: next part's references = confirmed enrolled speakers ∪ clips extracted from prior parts' speakers (longest ≥3 s segment, named with stable `S1`/`S2` tokens); `PartMerger` offsets times and maps labels → canonical `SPEAKER_%02d`. Retries 429/5xx twice (2 s/8 s backoff); 401/413 fail fast. Response segments carry no word timings (`words: []` — the interactive transcript UI tolerates this and interpolates).

**AssemblyAI**: compress (turns a 3 GB WAV into ~70 MB) → `POST /v2/upload` (raw body, `authorization` header, `upload(fromFile:)` so nothing large is held in memory) → `POST /v2/transcript` `{audio_url, speaker_labels, language_detection}` → poll `GET /v2/transcript/{id}` every 3 s, cancellation-aware. Maps `utterances[]`/`words[]` (ms → s) with word-level speakers; letters `A`/`B` normalized to `SPEAKER_%02d`. No client splitting ever (5 GB cap). No known-speaker support → library matching is skipped for this engine.

## Chat layer (`Services/Providers/Chat/`)

- `ChatProvider` protocol: `streamChat(messages:system:) -> AsyncThrowingStream<ChatStreamEvent, Error>` (`.token` / `.reasoning`), `contextCharacterBudget` (local 6 k, cloud 100 k — consumers truncate context with it), `isConfigured`. Default `generate()` accumulates tokens.
- Every provider exposes `modelIdentity` (concrete model name) — stamped onto assistant `ChatMessage.modelUsed` (shown under bubbles) and `RecordingSummary.modelUsed` (summary footer). Model attribution is a product requirement: anything a model generates records which model.
- `OpenAICompatibleChatProvider` — one class, three instantiations (base URL/model/key via closures so Settings edits apply live):
  - MiniMax: `https://api.minimax.io/v1` (international), default model `MiniMax-M3` (UserDefaults `miniMaxModel`; LegacySettingsMigrator v2 clears a stored old `MiniMax-M2` default)
  - OpenAI: `https://api.openai.com/v1`, default `gpt-4o-mini` (`openAIChatModel`)
  - Custom: base URL `customChatBaseURL`, model `customChatModel`, key `.custom`
  SSE via `URLSession.bytes` + chunk-boundary-safe `SSEParser`. Requests always send `max_tokens: 4096` (reasoning models otherwise churn for minutes). MiniMax-M3 quirks handled: `<think>…</think>` embedded in `content` deltas is rerouted to `.reasoning` via the stateful `ThinkTagFilter` (tags may split across chunks); explicit `reasoning`/`reasoning_content` fields honored; `base_resp.status_code != 0` on HTTP 200 → error; no `[DONE]` sentinel (stream ends on connection close); undecodable chunks skipped. Timeouts 30 s request / 600 s resource.
- `LocalMLXChatProvider` + `MLXServerProcess` (actor): persistent `generate.py --server` child — model loads once and stays warm. Line protocol: one JSON request per stdin line; child streams tokens to stdout and terminates each response with sentinel `\x1E<<END:ok>>` / `\x1E<<END:err:…>>`; readiness = `\x1E<<READY>>`. Stdout is drained into an actor buffer by the readability handler and consumers **poll** it — so timeouts fire even if the child never prints (stalled model download). Stderr always drained. Cancellation terminates the child; next request restarts it.
- `ChatService` (@Observable @MainActor): explicit user selection (`chatProviderID`) wins; otherwise auto: **MiniMax if keyed → OpenAI if keyed → local MLX**. `isActiveProviderReady` gates the chat UI.
- `ChatSessionView(context: .recording(r) | .global)` — single implementation for both chats; error bubble with Retry; interrupted streams kept and marked; per-recording history in `.chat.json`, global in `.global-chat.json`.

## Speaker voice library (`Services/SpeakerLibrary/`)

- `SpeakerLibraryStore` — `<storageDir>/SpeakerLibrary/library.json` (version, `autoMatchThreshold` default 0.70, speakers with `embeddings: [[Float]]`, clips, `recordingIDs`) + m4a clips under `clips/<uuid>/`. ISO8601 dates on **both** encode and decode (a mismatch here once silently wiped the library). Upsert by case-insensitive name enriches an existing speaker. **Must be re-`attach`ed when the storage directory changes** (StorageSettingsTab does this).
- Enrollment flow (TranscriptionView rename popover, "Remember this voice" default on): `ReferenceClipExtractor.selectCandidates` (clean non-overlapping segments ≥3 s, middle-10 s trim, 8–15 s total, max 3) → 16 kHz samples → `LocalFluidAudioEngine.extractEmbedding` (requires models; skips silently if absent) → clips via `AudioCompressor` → `enroll`.
- Matching: after each local transcription, cluster embeddings vs library via `SpeakerMatcher` (vDSP cosine, best-of-multiple-embeddings, threshold slider 0.50–0.90 in Settings → Speakers). Writes into `.speakers.json` only for keys the user hasn't set. Cloud: `referenceCandidates(limit: 4)` ranked by recordings-seen then recency feed OpenAI's known-speaker fields.

## Persistence

**Auto-processing**: `RecordingStore.onRecordingAdded` fires for genuinely new recordings/imports (never for migration/orphan adoption); app wiring enqueues transcription when `autoTranscribeNewRecordings` is on (**default true**). Post-transcription auto-summary then auto-names unnamed recordings, using `TranscriptionService.namingContext(for:)` — identified speakers + names of past calls with those speakers (via the voice library) so titles follow established series patterns.

**`RecordingStore`** (@Observable @MainActor) owns `recordings` + `categories`, persisted to `<storageDir>/recordings.json` (schemaVersion 1, entries with **relative** `fileName` for in-dir files / `absolutePath` otherwise). Load order: manifest → else one-time migration from UserDefaults key `"recordings"` (legacy key left as rollback backup; the manifest's existence is the migration marker) → drop entries with missing audio → **orphan adoption** (any untracked audio file in the dir becomes a Recording; `.md` present ⇒ `.done`; ≤4096-byte crash artifacts skipped) → status repair. Saves are debounced 500 ms + `saveNow()` on `willTerminateNotification`. **The directory is the source of truth** — a lost manifest self-heals. Category rename cascades into recordings; renaming onto an existing name **merges** (no duplicate entries); delete falls back to Uncategorized.

**Sidecars** (beside each audio file; formats unchanged from pre-overhaul — keep backward compatible):
| File | Contents | Writer |
|---|---|---|
| `<stem>.md` | Markdown transcript | TranscriptionService (MarkdownFormatter) |
| `<stem>.segments.json` | `[TranscriptionSegment]` word-level | TranscriptionService |
| `<stem>.speakers.json` | `[String: String]` id → display name | TranscriptionView pills + auto-match |
| `<stem>.summary.json` | RecordingSummary | SummarizationService |
| `<stem>.chat.json` | ChatHistory | ChatSessionView |
| `<id>.partial.json` | TranscriptionCheckpoint (deleted on success) — **NOT beside the audio**: lives in `~/Library/Application Support/AudioTranscriber/Checkpoints/`, keyed by recording UUID (`CheckpointLocation`); device-local resume state must never enter a synced library. Legacy in-library checkpoints migrate at load | LocalFluidAudioEngine |
| `<stem>.meta.json` | `RecordingMeta` — durable identity + user metadata (version, **id**, date, duration, name, category, engineUsed, fileSizeBytes, updatedAt; deliberately NO status) | RecordingStore (insert/update/load-backfill; no-op writes skipped so updatedAt stays honest) |
`Recording.allSidecarURLs` is the single deletion list — extend it when adding a sidecar.

**recordings.json is a rebuildable cache** as of the sync hardening: `.meta.json` is the durable metadata source (applied over manifest entries at load; orphan adoption reconstructs full identity from it, so a rebuilt or synced-in library keeps stable UUIDs, names, categories, attribution). Categories additionally live in the synced master list `<storageDir>/library.json` (`LibraryFile`: version/categories/updatedAt); load() unions manifest ∪ library.json ∪ adopted recordings' categories. All metadata edits must go through `store.update`/category APIs so the sidecar stays fresh. Every whole-file library write goes through `AtomicFile` (atomic replace; future NSFileCoordinator hook).

**Secrets**: Keychain only (`KeychainStore`, kSecClassGenericPassword, service = the fixed constant `com.audiortranscriber.AudioTranscriber` — NOT `Bundle.main.bundleIdentifier`, so a future iOS app with a different bundle id finds the same items; `SecretKey`: `openai.apiKey`, `minimax.apiKey`, `assemblyai.apiKey`, `custom.apiKey`). `set` with an empty/whitespace value is a **no-op** — removal is only ever the explicit `delete` (a transiently empty text field must never destroy a key); `set` returns a discardable `Bool` so the UI can surface failures. `InMemorySecretsStore` for tests. Never mirror secrets into UserDefaults.

**UserDefaults inventory** (add new keys to this list): `storageDirectory`, `llmModel`, `recordings` (legacy backup only), `defaultTranscriptionEngine`, `confirmCloudTranscription`, `autoSummarize`, `autoTranscribeNewRecordings` (default **true**), `liveTranscriptionPreview`, `chatProviderID`, `miniMaxModel` (default MiniMax-M3), `openAIChatModel`, `customChatBaseURL`, `customChatModel`, `diarizationClusteringThreshold`, `playbackRate`, `collapsedCategories`, `recordingFormat` (default aacHigh), `importCompression` (default ask), `rtf.<engineID>`, `didCleanupLegacyKeys.v1`, `didCleanupLegacyKeys.v2`, `iCloudSyncEnabled` (device-local), `iCloudContainerPath` (device-local cache written by CloudSyncManager.bootstrap), `preferredInputDeviceUID` (device-local; nil = Automatic), `recordSystemAudio` (default **true**; macOS system-audio tap), `silenceAutoStopMinutes` (default **20**; 0 disables the silence auto-stop), `longRecordingCheckInHours` (default **2**; 0 disables the "still recording?" check-in). The 13 preference keys listed in `SyncedDefaults.syncedKeys` additionally mirror through NSUbiquitousKeyValueStore (pull-into-defaults; LWW; local wins the initial reconcile).

**Summary sidecar v2**: `RecordingSummary` gained optional `keyPoints`, `decisions`, `topics`, `modelUsed` — old `.summary.json` files decode unchanged; the summary tab renders topics as tags and the sections with distinct icons.

## Recording & playback (`AudioRecorder`)

- AVAudioEngine input tap in the **native input format** (never convert in the tap callback — historic EXC_BREAKPOINT crash). The file format comes from `RecordingFormat.selected` (UserDefaults `recordingFormat`): **default AAC `.m4a` 96 kbps ≈ 45 MB/hour** (`aacHigh`), `aacCompact` 48 kbps, or 16-bit WAV ≈ 346 MB/hour. All use `AVAudioFile(forWriting:settings:commonFormat:.pcmFormatFloat32:interleaved:false)` — `commonFormat:` pins `processingFormat` to the tap's Float32 so encoding happens internally. The m4a container is finalized when `audioFile` is nil-ed on stop (deinit) — never read the file before that. Guarded fallback to native-format settings if the tap isn't Float32. First-write errors surface within ~300 ms instead of producing a dead stub file.
- **Import compression**: `RecordingStore.importAudioFiles` offers to convert uncompressed sources (wav/aiff/caf/flac — `RecordingStore.compressibleExtensions`) to AAC via `AudioCompressor.Spec.storage` (48 kHz mono 96 kbps); UserDefaults `importCompression` = ask (default) / always / never. **Compress-in-place**: sidebar context submenu (96 kbps / 48 kbps with per-recording size estimates) converts an existing WAV to `.m4a` with the *same stem* (all sidecars keep matching), duration-verified (±1 %) before the original is deleted; `Recording.fileURL` is `var` for exactly this swap. Live progress in `store.compressingProgress[id]` (shown in the sidebar row), success via `store.infoMessage` alert; `Recording.fileSizeBytes` caches sizes (manifest field, refreshed at load/insert/compress) and `formatAndSizeLabel` ("M4A · 40 MB") appears in rows and the detail header.
- Hardware init runs off the main thread (`Task.detached`) — `inputNode` access deadlocks on the main thread via coreaudiod TCC.
- **Segmented capture (device-change resilience, macOS)**: macOS silently stops AVAudioEngine when the input device changes shape (AirPods connect/disconnect, HFP profile switch). Each interruption finalizes the current segment file (`<stem>.segN.<ext>` in the spool) and starts a new one in the new native format; `stopRecording` renames a single segment into place (fast path) or stitches multiple via `AudioCompressor.concatenateSync` off-main (`isFinalizingRecording` published; per-segment converters handle mixed sample rates; output rate follows the first segment). Triggers: `.AVAudioEngineConfigurationChange` (per-engine observer), `AudioInputDeviceStore.onEffectiveInputChanged`, a 1 Hz watchdog (engine not running / file frames not growing for 8 s), and a tap-write-failure counter (~2 s of consecutive failures). Rebuild is attempted 3× then the recording is stopped and **saved** with a visible error. A failed stitch keeps the raw segments (spool sweep adopts them at next launch). The capture file is always **mono** — multi-channel input is summed in the tap (pure float arithmetic, never a converter).
- **Input device selection (macOS)**: `AudioInputDeviceStore` (`Services/Mac/`) enumerates Core Audio input devices, tracks the system default via hardware-property listeners, and holds the preference (UserDefaults `preferredInputDeviceUID`, device-local; nil = Automatic). The effective device is pinned onto the engine via `inputNode.auAudioUnit.setDeviceID`; a pinned-but-disconnected device falls back to the system default (`isUsingFallback` drives a warning label). Picker + toggle live in `RecordingControlView`; `AudioRecorder.inputDescription` publishes the live source label.
- **System audio capture (macOS 14.4+)**: `SystemAudioCapture` (`Services/Mac/`) creates a global Core Audio process tap (`CATapDescription(stereoGlobalTapButExcludeProcesses: [])`, private, unmuted) plus a private aggregate device combining the selected mic (clock master) with the drift-compensated tap; the aggregate becomes the engine's input, so the far side of AirPods calls and any played media land in the same mono file. UserDefaults `recordSystemAudio` (default **true**); first use triggers the System Audio Recording TCC prompt (`NSAudioCaptureUsageDescription`); any failure degrades to mic-only with a "(mic only)" note in `inputDescription`. Output-device switches don't interrupt a global tap.
- **Unattended-recording guardrails** (`Services/Shared/RecordingGuardrails.swift`, evaluated by the same 1 Hz timer as the watchdog, `AudioRecorder.evaluateGuardrails`): a recording once ran for 70 hours because nothing ever asked about it.
  - **Silence auto-stop**: the tap measures RMS + peak dBFS of every mono buffer it writes (vDSP, no allocation) into a lock-guarded `RecordingLevelMonitor`. `SilenceDetector` counts a buffer as *sound* if RMS ≥ −45 dBFS, **or** peak ≥ −35 dBFS (transients an RMS window averages away), **or** RMS ≥ noise floor + 8 dB and ≥ −70 dBFS. The noise floor falls instantly to the quietest recent buffer and rises at most 3 dB/min (capped at −45 dBFS), so continuous content can never pull it up into "silence". After `silenceAutoStopMinutes` (default **20**, 0 = off) of *unbroken* silence the recorder stops **and saves**, posts a notification and sets `errorMessage`. **Bias: every ambiguous case counts as sound** — one sounding buffer resets the whole clock, and a capture rotation restarts it (the gap was never measured). Real-audio proof lives in `SilenceDetectorRealAudioTests`.
  - **Long-recording check-in**: every `longRecordingCheckInHours` (default **2**, 0 = off) `AudioRecorder.pendingCheckIn` is set and `RecordingNotifier` posts an actionable banner (Keep Recording / Stop & Save, `recording-check-in` category, time-sensitive). The in-app alert is `recordingCheckInAlert()` — applied at the root on macOS, per-screen on iOS (a `fullScreenCover` swallows root-level presentations). `acknowledgeCheckIn()` pushes the next one a full interval out; **an unanswered check-in never stops a recording** — only the user or the silence rule does. `RecordingNotifier.shared` owns the `UNUserNotificationCenterDelegate` (wired in `AppBootstrap`) so banner actions reach the recorder while the app is in the background.
  - Both limits are visible before they act: the record screen and the Mac status bar show "No sound for N min" once silence passes 3 minutes.
- Duration: wall-clock display during recording; authoritative final = `file.length / processingFormat.sampleRate` (stitched recordings re-read the header). Auto-stop at 3.9 GB (WAV 4 GB header cap).
- Playback: AVAudioPlayer with `enableRate`; `playbackRate` persisted; `seek/seekAndPlay` drive the interactive transcript's word highlighting via a 0.05 s timer updating `playbackTime`.
- Tap also feeds `LiveTranscriber` (StreamingAsrManager, `.streaming` config; accepts any buffer format; preview-only, discarded at stop; never downloads models mid-recording).

## Views

`ContentView` (NavigationSplitView) → `RecordingListView` (search, collapsible category sections, context menus, engine submenu) | detail: `RecordingControlView` (record + live preview) / `TranscriptionView` (header + playback bar + tabs Transcript/Summary/Chat, split Transcribe button with per-engine costs, `CloudTranscribeConfirmSheet`, active/queued/paused/failed states with ETA + Pause/Cancel, speaker pills + enrollment popover, export menu) / `ChatSessionView` (.global). `InteractiveTranscriptView` = NSViewRepresentable NSTextView: word-click seeks audio, playback word highlighting (yellow background), search highlighting (orange underline — deliberately a different attribute so they don't clobber each other). It takes a `contentID` (the recording id) and **re-assigns `coordinator.onSeek` on every `updateNSView`** — SwiftUI reuses the NSView + Coordinator across sidebar selection changes, and a stale captured closure once made word-clicks play the previously viewed recording. `SettingsView` tabs: General / Transcription / AI Chat / Speakers / Storage.

## iOS app (`AudioTranscriber9000iOS`, iOS 17+)

Same module (`PRODUCT_MODULE_NAME: AudioTranscriber`), bundle `com.audiortranscriber.AudioTranscriber.ios`, iPhone-only. Shares all Services/Models + `Views/Shared/`; iOS UI in `Views/iOS/`: `RootView` → `RecordingsHomeView` (searchable category sections, fileImporter import, context menus, Record button → `RecordSheet` hosting the shared RecordingControlView) → `RecordingDetailView` (playback bar + Transcript/Summary/Chat tabs from shared pieces, ShareLink exports) + `SettingsHomeView` + `InteractiveTranscriptViewIOS` (UITextView twin driven by the same `TranscriptTextBuilder`). iOS-only services: `AudioSessionController` (AVAudioSession lifecycle: .playAndRecord before engine start, interruption/route-loss → finalize-and-save), `TranscriptionBackgroundCoordinator` (backgrounding while transcribing arms a UIBackgroundTask whose expiry pauses into the chunk checkpoint; foreground auto-resumes ONLY system pauses). Mac-only and absent on iOS: LocalMLX chat (child processes), NSSavePanel/ffmpeg exports, custom storage directory.

## iCloud sync (`Services/Sync/`)

**Design: the ubiquity container's Documents folder IS the library** (`iCloud.com.audiortranscriber.AudioTranscriber`; file-based, NOT CloudKit — the sidecar architecture + self-healing store map 1:1). Pieces:

- `SyncEngine` protocol with `ICloudSyncEngine` (NSMetadataQuery ubiquitous-documents scope → debounced `SyncChange` batches; `startDownloadingUbiquitousItem`/`evictUbiquitousItem`; download-status → `SyncItemState`) and `LocalFolderSyncEngine` (test fake: stub placeholders + injected batches). No NSFilePresenter, by design.
- `CloudSyncManager` (@Observable @MainActor): resolves the container ONCE off-main (`bootstrap()`) and caches the path in UserDefaults `iCloudContainerPath` so `RecordingStore.resolveStorageDirectory` can branch synchronously; external change batches → debounced `reloadFromStorageDirectory()` + speaker-library reload + conflict sweep; per-item `state(for:)` + `stateVersion` for row badges.
- `ConflictResolver`: pure policies — `.meta.json` LWW by `updatedAt`; `.speakers.json` union (newer file wins per key); categories `library.json` union; SpeakerLibrary per-speaker merge by id (union clips/embeddings/recordingIDs); content files newest-wins — applied over `NSFileVersion.unresolvedConflictVersionsOfItem`.
- `LibraryMigrator`: enable = compress legacy WAVs (existing verified swap) → copy with skip-if-same-size resume → verify (size + meta identity; zero writes into the container pre-switch) → repoint (`iCloudSyncEnabled=true` + reload + re-attach). The old local library is never touched (backup; `storageDirectory` still points there, so disable = repoint back).
- Cloud-mode store behavior: manifest cache relocates to `Application Support/AudioTranscriber/Cache/recordings-cloud.json` (never in the synced tree); load() treats hidden `.name.icloud` placeholder stubs as existing (evicted ≠ deleted) and adopts them via `.meta.json`; `AtomicFile` wraps in-container writes in `NSFileCoordinator(.forReplacing)`.
- UI: `CloudSyncSection` (Mac Storage tab + iOS Settings), `CloudSyncBadge` rows, Download/Remove-Download context items; play/transcribe on a placeholder triggers a download instead of failing.
- Secrets/prefs: `KeychainStore` stores keys as synchronizable items in the shared access group `Z6FHNWFTWR.com.audiortranscriber.AudioTranscriber.shared` (dual-read + lazy upward migration; graceful legacy fallback when signing lacks the entitlement). `SyncedDefaults` mirrors preferences via NSUbiquitousKeyValueStore.
