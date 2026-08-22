# Testing Guide

What exists, how to run it, and what "verified" means in this project. See [DEVELOPMENT.md](DEVELOPMENT.md) for the rules that these tests enforce.

## Test suites (Tests/AudioTranscriberTests/, `@testable import AudioTranscriber`)

**Unit — always run, no network, no models (as of 2026-08-22: totals incl. skipped gated suites are 301 on macOS / 298 on the iOS simulator). On a real iPhone the same 298 run with only 7 skipped, because the device has the app-container marker (gated real-mic recorder, real-model local-engine, and real-container scan suites run there).**

**UI (XCUITest, iOS only — `AudioTranscriberUITestsiOS`, `Tests/AudioTranscriberUITests/`)** drives the shipped app the way a person does. `RecordFlowUITests`: the app launches and is still in the foreground 15 s later (the launch watchdog kills at 10 s), the home list shows more than a single row when the library isn't empty (it skips with that reason when it is), and **pressing Record brings up the recording surface** — then leaves via Done without capturing anything, because on a device this runs against the real library. Run it with `-destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:AudioTranscriberUITestsiOS`. On a physical iPhone the runner needs **Settings → Privacy & Security → Developer → Enable UI Automation**; without it every device run fails with "Timed out while enabling automation mode", so the simulator run is the authoritative one and the device is covered by the in-process suites plus a launch-and-inspect pass (below).

| Suite | Covers |
|---|---|
| `TranscriptionLogicTests` | ChunkPlanner (snap/coverage/determinism), SpeakerAssigner (overlap/ties/nearest/normalize), TranscriptMerger (split rules, interpolation), TranscriptionCheckpoint (round-trip, resume skip, fingerprint discard), RTF/ETA math + formatter |
| `WordTimingAssemblerTests` | token→word assembly incl. the leading-space normalization gotcha |
| `RecordingStoreTests` | manifest round-trip, legacy UserDefaults migration, orphan adoption, crash-artifact skip, status repair, category rename-merge/delete cascades, sidecar deletion, tolerant status decode |
| `RecordingMetaTests` | `.meta.json` sidecar: written on insert/change (no-op updates leave the file byte-identical), **library reconstructs from the directory alone with stable UUIDs/names/categories** after deleting recordings.json, external (synced-in) meta edits win on reload, legacy-library backfill, delete cleanup |
| `CheckpointRelocationTests` | checkpoint path is ID-keyed under Application Support (never inside the library), legacy `<stem>.partial.json` migrates at load and launch repair sees it, delete cleans the relocated file. Tests that write real checkpoints must clean up (the location is global) |
| `SpoolTests` | finalize moves a spool file into the library; launch sweep salvages STALE crash leftovers (>4 KB, mtime >60 s, **readable duration**) and deletes stubs; unfinalized containers are quarantined to `Unfinished/` instead of becoming 0-second library entries; the sweep never touches the active recording, its `<stem>.segN` segments, or any freshly modified file (cross-instance protection) |
| `TranscriptionRetryTests` | auto-retry: 2 transient engine failures retried through to `.done` (exactly 3 attempts), persistent failure gives up after 3 with `lastError` persisted + cleared on re-enqueue, cancel during backoff wins; launch repair promotes stale `.processing/.partial/.paused` with a transcript and no checkpoint to `.done`, keeps `.partial` when a checkpoint exists, `.pending` when nothing on disk |
| `SegmentStitchTests` | `AudioCompressor.concatenateSync`: same-rate and MIXED-rate (24 k AirPods HFP + 48 k built-in) segments stitch to combined duration, output follows the first segment's rate, WAV output path, single-segment identity; `AudioInputDeviceStore.resolveEffective` policy (Automatic / pinned / disconnected-pinned fallback) |
| `ImportURLsTests` | platform-neutral import API: copy vs compress-to-m4a, compress flag ignored for already-compressed sources, always/never/ask policy resolution, estimate counts only compressibles |
| `ConflictMergeTests` | sync conflict policies: meta LWW by updatedAt, speaker-name union w/ newer-file-wins, category union, per-speaker library merge by id (clips/embeddings/recordingIDs union) |
| `CloudModeStoreTests` | cloud-mode store: storage dir resolves to the container, manifest cache stays OUT of the synced tree, evicted placeholder rows survive load via .meta.json and delete removes the stub |
| `MigrationAndWatcherTests` | full enable-sync cycle against the fake engine (compress → copy → verify → repoint; identity/categories/sidecars preserved; old library untouched; disable returns to local) + watcher change batch → debounced library reload |
| `SyncedDefaultsTests` | preference mirroring: initial reconcile prefers local, local edits push, remote changes pull, device-local keys never sync (fake NSUbiquitousKeyValueStore) |
| `IOSPlatformTests` (iOS-only) | AVAudioSession category switching + record-session precedence, SleepGuard idle-timer refcount, background coordinator (expiry-pause → auto-resume of system pauses only; user pauses survive; recording no-op guard) |
| `TranscriptTextBuilderTests` | shared transcript renderer: word ranges map back to exact text, same-speaker grouping under one header, interpolation fallback without word timings, case-insensitive search ranges, range-at-time + tap-to-seek lookup |
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
| `RecordingGuardrailTests` | Unattended-recording guardrails. Level math (known-amplitude sine → exact dBFS, digital silence → floor, loudest channel wins). `SilenceDetector`: digital silence stops exactly at the limit; **and, over hours of simulated time, never stops** a conversation with pauses, quiet distant speech, steady loud content, content sitting on the -45 dBFS line, or sparse transients; one sounding buffer resets the clock; a device-change restart resets it, a silence-triggered restart deliberately does not (so recovery can't defer the limit); slow noise-floor rise protects faint unvarying content for minutes. `LongRecordingCheckIn`: fires per interval, never bursts after a late wake, acknowledgement pushes the next out, 0 disables. `RecordingLevelMonitor`: wall-clock silence, missing buffers count as silence, safe under 4-way concurrent observation |
| `TrailingSilenceTrimTests` | Silent-tail trim: plan cuts a 180 s tail but keeps 15 s of padding after the last sound, returns **nil** when audio runs to the end or the tail is under a minute, and rejects unreadable files; passthrough trim of WAV and m4a lands the kept duration and shrinks the file while the tone survives; store op swaps in place (same URL, sidecars still matching, duration/size updated), reports "nothing to trim", and refuses while transcribing or for the active capture |
| `RecordingMergeTests` | Combining recordings, on real audio: a loud part plus a near-silent part merge to the summed duration, and **the halves swap when the order swaps** (level of each half measured from the merged file) — the ordering guarantee the feature exists for; the result is dated from the earliest part and starts `.pending`; originals survive by default and are removed with their sidecars only when asked; refuses a single part, a part being transcribed, and the recording being captured; plan totals come from the files, not a stale manifest duration, and an unreadable part throws |
| `CombineSheetLiveTests` (iOS) | Mounts `CombineRecordingsSheet` in a real UIWindow in the hosted app and reads the **accessibility tree** (SwiftUI draws its text, so there are no UILabels to find): title, seeded part, "Order" header, Add Recording, Combine, "Pick at least two", and the Move earlier/later + Remove controls. On a device the Form's rows only lay out when the screen is awake and the host app is on screen, so the row-level half **skips with that reason** instead of failing — in the simulator it is authoritative |
| `CloudScanSafetyTests` | The rules that came out of the iOS launch-watchdog kill. The download gate (`CloudPlaceholder.isDownloaded`/`dataIfDownloaded`/`awaitingDownload`) over a local file, a missing file and a placeholder stub; orphan adoption **waits** for a `.meta.json` that is still in the cloud and then adopts it with the sidecar's identity; a master category list that can't be read is never written over; the speaker library isn't wiped when its file is a placeholder; `loadAsync()` returns the same library as `load()` **and leaves the main actor free while it scans** (a main-actor ticker must get a turn) |
| `CloudLibraryScanIntegrationTests` (gated) | The REAL iCloud library on this machine/device. (1) A read-only walk: every sidecar and audio header goes through the download gate, the pass must finish in under 5 s (the watchdog budget is 10 s) and must not pull a single audio file down — on the iPhone, 49 recordings in 0.08 s with nothing materialized. (2) The other half of the contract: the smallest not-yet-downloaded recording downloads on request and then reads its header (what Play needs), and is evicted again so the device is left as it was |
| `SilenceDetectorRealAudioTests` | The guardrail replayed over REAL audio (tap-sized buffers): the 63 s conversation fixture reads as at most **1.1 s** of silence, a -30 dB whisper-level copy at most **3.4 s** (limit: 1200 s), and a dithered silent capture does trip a shortened limit. Gated variant sweeps the user's whole library (below) |
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

> **Running gated tests on a real iPhone**: the iOS sandbox can't see `/tmp`, so `IntegrationGate` also accepts the marker inside the app's Documents container:
> ```bash
> xcrun devicectl device copy to --device <device-uuid> \
>   --domain-type appDataContainer --domain-identifier com.audiortranscriber.AudioTranscriber.ios \
>   --source audiotranscriber-integration-tests --destination Documents/audiotranscriber-integration-tests
> xcodebuild -project AudioTranscriber9000.xcodeproj -scheme AudioTranscriber9000iOS \
>   -destination "platform=iOS,id=<xcodebuild-device-id>" -allowProvisioningUpdates \
>   -only-testing:AudioTranscriberTestsiOS/RecorderSpoolIntegrationTests test
> ```
> The device id for `-destination` comes from `-showdestinations` and differs from the `devicectl` UUID. Delete the marker (Files.app → the app's folder) when done. A freshly installed build has **no microphone TCC grant** — launch the app once and tap Allow, or every recorder test records digital silence.
>
> **Wake the phone right before the recorder suites.** iOS will not start microphone capture for a process that is in the background, so once the display sleeps every `RecorderSpoolIntegrationTests` case fails with "recording never started — mic permission?" even though the grant is fine. A `launch` before `xcodebuild test` is not enough — the incremental build eats the awake window. Build first, wake second, run third:
> ```bash
> xcodebuild … -destination "platform=iOS,id=<id>" -allowProvisioningUpdates build-for-testing
> xcrun devicectl device process launch --device <uuid> --terminate-existing com.audiortranscriber.AudioTranscriber.ios
> xcodebuild … -destination "platform=iOS,id=<id>" test-without-building \
>   -only-testing:AudioTranscriberTestsiOS/RecorderSpoolIntegrationTests
> ```
> Run the rest of the suite separately (`-skip-testing:AudioTranscriberTestsiOS/RecorderSpoolIntegrationTests`) so a four-minute pass can't put the device to sleep in the middle of the mic tests.
>
> `LocalEngineIntegrationTests` falls back to `Documents/test_recording.wav` in the app container when the repo fixture isn't reachable, so the same `devicectl device copy to` trick runs the real transcription pipeline on the phone (first run downloads ~1.5 GB of models onto the device).

> **Launch-and-inspect pass on the phone** (what caught the launch-watchdog kill, and how to confirm a fix without XCUITest):
> ```bash
> xcrun devicectl device install app --device <uuid> "<DerivedData>/Build/Products/Debug-iphoneos/Audio Transcriber 9000.app"
> xcrun devicectl device process launch --device <uuid> --terminate-existing com.audiortranscriber.AudioTranscriber.ios
> sleep 30 && xcrun devicectl device info processes --device <uuid> | grep -i transcrib   # still alive?
> # what the app itself thinks its library is:
> xcrun devicectl device copy from --device <uuid> --domain-type appDataContainer \
>   --domain-identifier com.audiortranscriber.AudioTranscriber.ios --user mobile \
>   --source "Library/Application Support/AudioTranscriber/Cache/recordings-cloud.json" --destination ./cloud.json
> ```
> A watchdog kill leaves a report in `~/Library/Logs/CrashReporter/MobileDevice/<device name>/` — `.ips` files are JSON; the second line parses with `json.loads` and the triggered thread's frames name the blocking call. `EXC_CRASH (SIGKILL)` + `0x8BADF00D` + "scene-update watchdog transgression" means the main thread was blocked, not that the code threw.

> **Quit any running Audio Transcriber 9000 instance before running tests** — not just the gated recorder ones. `KeychainFieldLiveTests` drives a real field editor inside an NSWindow in the test host and fails (`testEmptyingFieldDoesNotDeleteStoredKey`) when another instance holds the key window; it passes immediately once the app is quit. And for the recorder suites: Tests run inside a fully live app (AppBootstrap wires the real stores), and a SECOND running instance shares the global spool: its cloud-watcher reloads sweep the spool and once adopted the test recorder's live segment files into the user's REAL iCloud library mid-test (0-bytes-on-disk failures, junk `segN.m4a` files in the container). The sweep now has stem + mtime guards, but an old binary (e.g. a stale /Applications copy) predates them.

| Test | Proves | Baseline (M1 Max, 2026-07) |
|---|---|---|
| `LocalEngineIntegrationTests` | Full local pipeline on the repo's 63 s 2-speaker fixture (`test_recording.wav`): segments, **exactly 2 speakers**, monotonic word times, embeddings returned, RTF recorded | 2.4 s warm (M1 Max); **19.1 s warm on iPhone 16 Pro Max** = 3.3× realtime, 165 s on the first run incl. the ~1.5 GB model download (2026-07-27) |
| `ResumeIntegrationTests` | Store+queue+real engine on a real 18-min recording: pause mid-ASR (2/6 chunks), **fresh service resumes at part 3/6**, full coverage, checkpoint cleaned | 29 s total incl. pause cycle |
| `LongFileSmokeTests` (2 h) | The real 2 h 07 m / 1.4 GB recording end-to-end (read-only on the source; checkpoint in temp): 43 chunks, 247 segments, 9 695 words, 2 speakers, 100 % coverage | 142 s (53×) |
| `LongFileSmokeTests` (5 h) | The real 4 h 56 m / **3.4 GB** recording — the file whose >2 GB payload crashed the old single-shot loader with error -40: 99 chunks, 544 segments, 100 % coverage via `WindowedAudioLoader` | 362 s (49×) |
| `DiarizerThresholdSweepTests` | Tuning harness: speaker count per clusteringThreshold on the fixture (0.85 ⇒ 2 ✓) | ~10 s |
| `RecorderSpoolIntegrationTests` | Real-mic record flow (6 tests): **`testMicrophoneCapturesRealSignal`** proves the capture path is actually live on THIS device — a real room is never digitally silent, so an all-zero file means denied mic permission or a dead input (Mac: peak ≈ -25 dBFS; it is how the iPhone's missing TCC grant was found); live file streams into the spool (never the library), stop finalizes the container and renames it into the library with header-verified duration, spool left clean; the REAL capture-interruption path (`captureInputChanged` mid-recording) rotates a segment, keeps recording, and stitches both halves (≥3.5 s of 5 s wall); the **silence guardrail** (thresholds forced so any room reads as silent) stops and SAVES with a message; **silence recovery** rotates capture twice then stops rotating (capped) while the recording continues; the **check-in** fires, is cleared by "Keep Recording", re-fires, and never stops the recording on its own. Forces `recordSystemAudio=false` for the run (no TCC prompt unattended) and restores it | ~40 s |
| `SilenceDetectorRealAudioTests` (library sweep) | Replays **all 55 recordings in the real library** through the silence detector and asserts the property that matters: every stretch it would act on contains no audible signal. Result 2026-07-27: exactly 2 stretches pass the 20-min limit — 113 min of literal -120 dBFS (all-zero) at the end of a 4 h recording and 47 min mid-way through another, i.e. dead-input failures. Loudest sample inside them: -120 dBFS and -69 dBFS (AAC codec noise over -87 dBFS RMS). Read-only on user data | ~15 s |
| `DiagnosticTranscribeTests` | On-demand forensics harness: writes an audio path into `/tmp/audiotranscriber-diagnose-file`, then `-only-testing:` this suite to run the full local pipeline on ANY file with a scratch checkpoint (never touches real sidecars). Used to reproduce user-reported failures with real models | file-dependent |
| `RealICloudSmokeTests` (Mac, needs full signing + iCloud account) | Migrates a SCRATCH library into the REAL ubiquity container with the real ICloudSyncEngine (compress → copy → verify → repoint; engine reports uploading/current), disable returns to local, all scratch files removed from the container. Isolated defaults — the user's library/settings untouched | ~1 s |

Long real samples referenced by the integration tests live in `~/Documents/AudioTranscriber/` (tests `XCTSkip` when absent).

## Commands

```bash
# Everything unit (integration auto-skips without the marker):
xcodebuild -project AudioTranscriber9000.xcodeproj -scheme AudioTranscriber9000 -configuration Debug test
# Build only:
xcodebuild -project AudioTranscriber9000.xcodeproj -scheme AudioTranscriber9000 -configuration Debug build
```

Regenerate the project first if files changed: `xcodegen generate`.

## iOS (simulator)

```bash
# Build + full unit suite on the simulator (same Tests/ sources; the 4
# os(macOS)-guarded suites compile out — expect 188 tests there vs 195 on Mac):
xcodebuild -project AudioTranscriber9000.xcodeproj -scheme AudioTranscriber9000iOS \
  -destination 'platform=iOS Simulator,name=iPhone 17' test
# Install + launch for manual probing:
xcrun simctl privacy booted grant microphone com.audiortranscriber.AudioTranscriber.ios
xcrun simctl install booted <DerivedData>/Build/Products/Debug-iphonesimulator/"Audio Transcriber 9000.app"
xcrun simctl launch booted com.audiortranscriber.AudioTranscriber.ios
xcrun simctl io booted screenshot /tmp/shot.png
```

- The `/tmp/audiotranscriber-integration-tests` marker file IS visible from simulator test processes (sim apps are host processes) — the same gate works.
- **FluidAudio runs on the sim, CPU-only (no ANE)**: the 63 s fixture pipeline (`LocalEngineIntegrationTests`) ≈ **18 s** vs 2.4 s on the M1 Max — fine for correctness runs; never calibrate RTF expectations there.
- Skip the ~1.5 GB model download by pre-seeding the host cache into the app container:
  `cp -R ~/Library/Application\ Support/FluidAudio "$(xcrun simctl get_app_container <udid> com.audiortranscriber.AudioTranscriber.ios data)/Library/Application Support/"`
- Prefer a dedicated simulator device; don't fight other projects over an already-booted one (another app can keep re-foregrounding itself).

## Signing states (matters for what can run)

- **Fully signed** (Xcode logged into the Apple ID, automatic signing, team Z6FHNWFTWR): everything works incl. iCloud entitlements. Build with `-allowProvisioningUpdates` at least once after entitlement changes.
- **Ad-hoc interim** (Apple ID session expired): an ad-hoc app carrying the restricted iCloud entitlements BUILDS but cannot LAUNCH — run Mac tests with
  `CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="-" DEVELOPMENT_TEAM="" CODE_SIGN_ENTITLEMENTS=""`
  (no entitlements → no mic for the gated recorder test; everything else runs; sync logic is fake-engine-tested anyway). Simulator builds are unaffected either way.

## Real-iCloud manual checklist (needs full signing + the user's Apple ID)

1. Mac: enable sync in Settings → Storage → migration sheet runs (compress → copy → verify → switch); verify `~/Library/Mobile Documents/iCloud~com~audiortranscriber~AudioTranscriber/Documents/` mirrors the library; watch uploads with `brctl monitor` / `brctl log -w`.
2. Record → file appears in the spool, then the container after stop; transcribe → checkpoint stays in Application Support; pause/resume mid-job.
3. Second device (iPhone with the app; the iOS **Simulator's** iCloud is flaky — prefer hardware): library appears; rename/recategorize on one device → the other updates via the watcher; evict → placeholder badge; play → downloads then plays.
4. Conflict drill: airplane-mode both devices, rename the same recording differently, reconnect → newest `updatedAt` wins, no duplicate rows; edit speaker names on both → union survives.
5. One-time re-grants after the signing switch: microphone TCC prompt, Keychain access prompts for pre-existing API keys (the keys then auto-migrate to iCloud Keychain).
6. Kill-switch: sign out of iCloud → the app falls back to the local library; no crash, no data loss.

## UI verification (osascript)

The app must be launched and probed before claiming UI work done:

```bash
open ~/Library/Developer/Xcode/DerivedData/AudioTranscriber9000-*/Build/Products/Debug/"Audio Transcriber 9000.app"
osascript -e 'tell application "System Events" to get name of every process whose name contains "Audio Transcriber"'
```

Hard-won accessibility notes:
- Sidebar outline path: `outline 1 of scroll area 1 of group 1 of splitter group 1 of group 1 of window 1`. Row 1 = search field, rows 3–5 = action buttons (New Recording / Import / Chat with All), section headers between, recordings follow. Select rows with `set selected of row N … to true` — `click` alone often doesn't update the SwiftUI selection.
- Settings tabs are toolbar buttons: `every button of toolbar 1` of the settings window (open with `keystroke "," using command down`). Expect: General, Transcription, AI Chat, Speakers, Storage.
- SwiftUI `Menu(primaryAction:)` (the split Transcribe button) does not respond to `AXPress` — but it does respond to a **synthetic mouse click at its coordinates**, which is how the whole transcribe-progress flow was verified end to end. Read `position`/`size` off the AX element, then post the click with a tiny CGEvent helper (`swiftc` a 10-line program that posts `.mouseMoved`/`.leftMouseDown`/`.leftMouseUp` at a point via `CGEvent(mouseEventSource:…).post(tap: .cghidEventTap)`); Terminal already has the Accessibility grant that this needs. Same trick opens a `Menu`'s list: click the pop-up, then read `position` of `menu item N of menu 1` and click that. Two cautions: with a menu already open, further System Events queries **hang** (dismiss with `key code 53` first — note that also closes an enclosing sheet), and `AXPress` on the *sheet's* plain buttons works fine, so only the menus need the mouse. `screencapture` returns the desktop wallpaper without a Screen Recording grant, so don't rely on screenshots.
- In-process view mounting is still the right tool when the control is genuinely unreachable or the assertion is about content rather than clicking (`KeychainFieldLiveTests`, `CombineSheetLiveTests`), as are integration tests for whole flows (`ResumeIntegrationTests`).
- Many SwiftUI controls expose no `name`; probe `value` of static texts and `description` of buttons.

## Manual checklist for release-grade changes

- Record 30 s → live preview text appears → stop → auto-transcribe (if enabled) → transcript/summary tabs correct; `afinfo` shows 16-bit LE WAV.
- Queue 2+ recordings → serial processing, queue positions, pause → Resume, cancel → Pending.
- Force-quit mid-transcription → relaunch shows "Partially transcribed" → Resume completes with continuous timestamps.
- With real keys: one short + one >2 h recording via OpenAI (watch part splitting) and AssemblyAI; confirm cost sheet numbers are sane.
- Enrollment E2E: name a speaker with "Remember this voice" on recording A → transcribe recording B with the same voice → auto-named; Settings → Speakers shows the voice, ▶ plays the clip.
- Categories: create/move/rename-onto-existing (merges)/delete (falls back), collapse state survives relaunch.
- Storage dir switch: library swaps, voice enrollments follow (new SpeakerLibrary dir).
