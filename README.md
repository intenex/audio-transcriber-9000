# Audio Transcriber 9000

A native macOS app for recording audio, transcribing speech to text with speaker diarization, and interacting with your recordings through AI-powered summarization and chat.

**Requires Apple Silicon (M series).** Intel Macs are not supported.

---

## Features

- **Recording** — Record audio directly from any microphone. Live timer, live transcript preview while you speak, Space bar shortcut, sleep prevention during long sessions.
- **Import** — Import existing audio files (wav, mp3, m4a, etc.) via Cmd+I.
- **On-device transcription** — [FluidAudio](https://github.com/FluidInference/FluidAudio) running Parakeet TDT v3 + pyannote speaker diarization on the Apple Neural Engine. Roughly 30–100× realtime, fully offline and private, with word-level timestamps.
- **Resumable jobs** — Long transcriptions checkpoint every ~3 minutes of audio. Pause anytime, quit the app, and resume exactly where it left off. Accurate time-remaining estimates calibrated to your machine.
- **Transcription queue** — Queue several recordings; they process one after another with progress and notifications.
- **Cloud engines (optional)** — Per-recording choice of OpenAI `gpt-4o-transcribe-diarize` (with enrolled-voice references) or AssemblyAI (best for very long files — single upload, no splitting). Cost estimates shown before sending; audio is compressed to 16 kHz mono AAC first.
- **Speaker voices** — Name a speaker once and the app remembers their voice (on-device embeddings). Future recordings are auto-labeled; cloud transcriptions receive reference clips so speakers come back already named.
- **Summarization** — Auto-generates a summary, action items, and a suggested name after each transcription.
- **Chat** — Ask questions about one recording or all of them. Providers: MiniMax (international endpoint), OpenAI, any OpenAI-compatible custom endpoint, or local mlx-lm.
- **Categories** — Group recordings into collapsible sidebar sections (e.g. Work, Therapy, Ideas).
- **Interactive transcript** — Click any word to play from that moment; the current word highlights during playback. Per-transcript search, speaker renaming, playback speed control and scrubbing.
- **Export** — Transcript/summary/chat as Markdown (with your custom speaker names), audio as WAV or size-estimated MP3.

---

## Requirements

- **macOS 14.0 (Sonoma)** or later, **Apple Silicon** (M1+)
- **Xcode 16+** and **[XcodeGen](https://github.com/yonaskolb/XcodeGen)** to build from source
- ~1.5 GB one-time speech-model download (automatic on first transcription, or from Settings → Transcription)

Optional:
- **API keys** for cloud engines/chat (OpenAI, AssemblyAI, MiniMax) — entered in Settings, stored in the macOS Keychain
- **Miniconda + mlx-lm** only if you want fully local AI chat/summaries:
  `conda create -n transcriber python=3.11 && conda run -n transcriber pip install mlx-lm`

---

## Build & Run

```bash
xcodegen generate
xcodebuild -project AudioTranscriber9000.xcodeproj -scheme AudioTranscriber9000 -configuration Debug build
open ~/Library/Developer/Xcode/DerivedData/AudioTranscriber9000-*/Build/Products/Debug/"Audio Transcriber 9000.app"
```

Grant microphone access in System Settings → Privacy & Security → Microphone when prompted.

Run tests:

```bash
xcodebuild -project AudioTranscriber9000.xcodeproj -scheme AudioTranscriber9000 test
# Real-model integration tests (downloads models on first run):
touch /tmp/audiotranscriber-integration-tests
xcodebuild -project AudioTranscriber9000.xcodeproj -scheme AudioTranscriber9000 test \
  -only-testing:AudioTranscriberTests/LocalEngineIntegrationTests
rm /tmp/audiotranscriber-integration-tests
```

---

## Storage layout

Recordings live in `~/Documents/AudioTranscriber/` (configurable in Settings → Storage). Each recording keeps sidecar files next to its WAV:

| File | Contents |
|---|---|
| `recordings.json` | Library manifest (names, statuses, categories) |
| `<name>.md` | Markdown transcript |
| `<name>.segments.json` | Word-level timestamped segments |
| `<name>.speakers.json` | Speaker ID → display-name map |
| `<name>.summary.json` | Summary, action items, suggested name |
| `<name>.chat.json` | Per-recording chat history |
| `<name>.partial.json` | Resumable transcription checkpoint (deleted on completion) |
| `SpeakerLibrary/` | Enrolled voice embeddings + reference clips |

The directory is the source of truth: drop a `.wav` in and it appears in the app; the manifest heals itself.

---

## Distribution

`./build-release.sh` builds Release and produces `build/AudioTranscriber9000.dmg`. Builds are ad-hoc signed; recipients right-click → Open the first time.

---

## Architecture notes

- SwiftUI + `@Observable`, macOS 14+. No sandbox (subprocess + arbitrary storage-dir access).
- Transcription engines implement one `TranscriptionEngine` protocol: `LocalFluidAudioEngine` (chunked, checkpointed, cancellable), `OpenAITranscriptionEngine` (25 MB part splitting + cross-part speaker continuity), `AssemblyAITranscriptionEngine` (upload + poll).
- Chat providers implement `ChatProvider`: one OpenAI-compatible SSE client covers MiniMax/OpenAI/custom; `LocalMLXChatProvider` keeps a warm `generate.py --server` child.
- API keys in Keychain; realtime-factor ETA calibration in UserDefaults; per-machine.
