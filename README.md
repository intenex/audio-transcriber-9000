# Audio Transcriber 9000

A native macOS app for recording audio, transcribing speech to text with speaker diarization, and interacting with your recordings through AI-powered summarization and chat.

**Requires Apple Silicon (M series).** Intel Macs are not supported.

---

## Features

- **Recording** — Record audio directly from any microphone. Live timer display, Space bar shortcut to start/stop.
- **Import** — Drag in or import existing audio files (wav, mp3, m4a, etc.) via Cmd+I.
- **Transcription** — Converts speech to text using [whisperX](https://github.com/m-bain/whisperX) with word-level timestamps.
- **Speaker diarization** — Identifies and labels who said what (SPEAKER_00, SPEAKER_01, etc.) using pyannote.audio.
- **Summarization** — Auto-generates a summary, action items, and a suggested recording name after each transcription.
- **Chat** — Ask questions about any individual recording, or chat across all recordings at once.
- **Search** — Search by keyword across all recording names and transcript content from the sidebar. Find-in-transcript with highlighting in the detail view.
- **Rename** — Rename recordings manually or use the AI-suggested name with one click.
- **Export** — Copy transcript to clipboard or export as a Markdown file.

---

## Requirements

- **macOS 14.0 (Sonoma)** or later
- **Apple Silicon Mac** (M1/M2/M3) — required for the mlx-lm AI features
- **Miniconda** — manages the Python environment
- **Xcode** — to build the app from source
- **[XcodeGen](https://github.com/yonaskolb/XcodeGen)** — to generate the `.xcodeproj` (setup.sh installs this)
- **HuggingFace account** — for speaker diarization model access (free)

---

## First-Time Setup

### 1. Install Miniconda

If you don't have conda, install [Miniconda](https://docs.conda.io/en/latest/miniconda.html):

```bash
# Download and run the Apple Silicon installer
curl -O https://repo.anaconda.com/miniconda/Miniconda3-latest-MacOSX-arm64.sh
bash Miniconda3-latest-MacOSX-arm64.sh
# Restart your terminal after installation
```

### 2. Get a HuggingFace token

Speaker diarization requires access to pyannote.audio models, which are gated behind a free HuggingFace account:

1. Create a free account at [huggingface.co](https://huggingface.co)
2. Generate an access token at [huggingface.co/settings/tokens](https://huggingface.co/settings/tokens)
3. Accept the model license terms for both of these (just click "Accept" on each page while logged in):
   - [pyannote/speaker-diarization-community-1](https://huggingface.co/pyannote/speaker-diarization-community-1)
   - [pyannote/segmentation-3.0](https://huggingface.co/pyannote/segmentation-3.0)

### 3. Clone the repo and run setup

```bash
git clone <this-repo>
cd audio-transcriber
./setup.sh
```

`setup.sh` does the following automatically:

- Installs XcodeGen via Homebrew (if not already installed)
- Creates a `transcriber` conda environment with Python 3.11
- Installs all Python dependencies (whisperX, pyannote.audio, torch, mlx-lm, etc.)
- Pre-downloads the Whisper `large-v3` model weights (~3GB)
- Pre-downloads the default AI model for summarization/chat — `mlx-community/Mistral-7B-Instruct-v0.3-4bit` (~4GB)
- Generates the Xcode project

> **Note:** Setup downloads ~7GB of model weights total. Plan for 10–30 minutes depending on your internet connection.

### 4. Build and open in Xcode

```bash
open AudioTranscriber9000.xcodeproj
```

Build and run with Cmd+R. The app is **not notarized**, so the first time you open it outside of Xcode, right-click → Open to bypass Gatekeeper.

### 5. Grant microphone permission

On first launch, macOS will ask for microphone access. If you miss the prompt, go to:

**System Settings → Privacy & Security → Microphone → Audio Transcriber 9000**

### 6. Paste your HuggingFace token

Open **Settings** (gear icon in sidebar) → **General** → paste your token in the HuggingFace Token field.

---

## Architecture

```
audio-transcriber/
├── AudioTranscriber/
│   ├── App/
│   │   ├── AudioTranscriberApp.swift   # App entry point, environment injection
│   │   ├── ContentView.swift           # Root NavigationSplitView
│   │   └── Theme.swift                 # AppTheme colors and gradients
│   ├── Models/
│   │   ├── Recording.swift             # Recording struct (id, fileURL, name, status)
│   │   ├── Transcription.swift         # TranscriptionResult, MarkdownFormatter
│   │   ├── Summary.swift               # RecordingSummary struct
│   │   └── ChatMessage.swift           # ChatMessage, ChatRole, ChatHistory
│   ├── Services/
│   │   ├── AudioRecorder.swift         # AVAudioEngine recording, playback, import
│   │   ├── TranscriptionService.swift  # Runs transcribe.py subprocess
│   │   ├── LLMService.swift            # Runs generate.py subprocess (mlx-lm)
│   │   └── SummarizationService.swift  # Prompt construction, summary JSON parsing
│   │   └── SearchService.swift         # Exact and natural-language search
│   └── Views/
│       ├── RecordingListView.swift     # Sidebar: list, search, rename, global chat
│       ├── RecordingControlView.swift  # Hero recording screen (no selection)
│       ├── TranscriptionView.swift     # Detail: transcript / summary / chat tabs
│       ├── ChatView.swift              # Per-recording AI chat
│       ├── GlobalChatView.swift        # Cross-recording AI chat
│       └── SettingsView.swift          # General / Storage / AI settings tabs
├── scripts/
│   ├── transcribe.py                   # whisperX pipeline, emits JSON to stdout
│   ├── generate.py                     # mlx-lm streaming generation
│   ├── environment.yml                 # Conda environment spec
│   └── requirements.txt               # pip dependencies
├── setup.sh                            # First-time setup script
├── build-release.sh                    # Builds release DMG
└── project.yml                         # XcodeGen project spec
```

### How transcription works

1. Swift launches `conda run -n transcriber python scripts/transcribe.py <audio> <hf_token>` as a subprocess
2. The script loads whisperX (faster-whisper backend), transcribes, aligns word timestamps, and runs pyannote.audio diarization
3. Progress is emitted to **stderr** as `PROGRESS:<percent>:<message>` lines, parsed by Swift's `readabilityHandler`
4. Final JSON is emitted to **stdout** and parsed by Swift after the process exits
5. Swift writes a `.md` sidecar file next to the audio file with formatted speaker-labeled markdown

### How AI features work

1. Swift launches `conda run -n transcriber python scripts/generate.py --messages <json> ...`
2. The script loads the mlx-lm model (cached in `~/.cache/huggingface/hub/`) and streams tokens to **stdout**
3. For chat (streaming), Swift reads tokens via `readabilityHandler` as they arrive and yields them through an `AsyncThrowingStream`
4. For summarization (non-streaming), Swift reads full stdout after the process exits and parses JSON

### Sidecar files

Each recording `recording_<id>.wav` can have:

- `recording_<id>.md` — full speaker-diarized transcript (Markdown)
- `recording_<id>.summary.json` — AI-generated summary, action items, suggested name
- `recording_<id>.chat.json` — per-recording chat history
- `.global-chat.json` — global chat history (in storage directory root)

---

## Settings

| Setting           | Location | Description                                                                               |
| ----------------- | -------- | ----------------------------------------------------------------------------------------- |
| HuggingFace Token | General  | Required for speaker diarization                                                          |
| Whisper Model     | General  | `large-v3` recommended; smaller models are faster                                         |
| Storage Location  | Storage  | Where recordings are saved (default: `~/Documents/AudioTranscriber/`)                     |
| AI Model          | AI       | mlx-lm model ID from HuggingFace (default: `mlx-community/Mistral-7B-Instruct-v0.3-4bit`) |

---

## AI Features

AI features require `mlx-lm` installed in the `transcriber` conda environment. If you ran `setup.sh`, it's already installed. If not:

```bash
conda run -n transcriber pip install mlx-lm
```

**Summarization** runs automatically after each transcription if the AI is available. It generates:

- A 2–3 paragraph summary
- A bulleted action items list
- A suggested 5-word recording name

**Chat** lets you ask questions about a specific recording's transcript. The full transcript (up to ~6,000 words) is passed as context.

**Global Chat** builds a manifest of all recordings (names, dates, summaries, transcript previews) and lets you ask questions across your entire library.

The default model (`mlx-community/Mistral-7B-Instruct-v0.3-4bit`) is ~4GB and runs entirely on-device. You can switch to any mlx-community model in Settings → AI.

---

## Building for Distribution

```bash
./build-release.sh
```

This produces `build/AudioTranscriber9000.dmg` — a drag-to-install DMG with a symlink to `/Applications`.

The build is **ad-hoc signed** (not notarized). Recipients will need to right-click → Open the first time to bypass Gatekeeper. For notarized distribution without the warning:

1. Enroll in the [Apple Developer Program](https://developer.apple.com/programs/) ($99/year)
2. Set your team ID in `project.yml`
3. Sign, notarize, and staple:
   ```bash
   codesign --deep --force --sign "Developer ID Application: Your Name" "build/.../Audio Transcriber 9000.app"
   xcrun notarytool submit build/AudioTranscriber9000.dmg --apple-id you@email.com --team-id YOURTEAMID --wait
   xcrun stapler staple build/AudioTranscriber9000.dmg
   ```

---

## Conda Environment

The `transcriber` environment is defined in `scripts/environment.yml`. Key packages:

| Package                | Purpose                               |
| ---------------------- | ------------------------------------- |
| `whisperx`             | Speech-to-text with word alignment    |
| `pyannote.audio`       | Speaker diarization                   |
| `torch` / `torchaudio` | ML backend for both of the above      |
| `mlx-lm`               | On-device LLM inference via Apple MLX |
| `scipy`, `soundfile`   | Audio file handling                   |

To update the environment after pulling changes:

```bash
conda env update -n transcriber -f scripts/environment.yml --prune
```

To start fresh:

```bash
conda env remove -n transcriber
./setup.sh
```

---

## Troubleshooting

**"Microphone access denied"**
Go to System Settings → Privacy & Security → Microphone and enable the app. Due to macOS TCC (Transparency, Consent, and Control), the permission prompt only appears once — if you denied it, you must grant it manually.

**Transcription fails immediately**

- Check that your HuggingFace token is set in Settings → General
- Confirm you accepted the model terms for both pyannote models (links above)
- Check that the `transcriber` conda environment exists: `conda env list`

**AI features show "Not Available"**

- Run `conda run -n transcriber python -c "import mlx_lm"` in Terminal — if it errors, reinstall: `conda run -n transcriber pip install mlx-lm`
- Click "Check" in Settings → AI to re-run the availability check

**First transcription is very slow**
The Whisper model loads from disk each time (no persistent process). `large-v3` takes 30–60 seconds to initialize on first load. Smaller models (`medium`, `small`) are faster with some quality tradeoff.

**App quits unexpectedly after granting mic permission**
This is a known macOS behavior with ad-hoc signed apps — the TCC database uses code-hash-based entries that go stale after each build. Quit and reopen the app; if it persists, re-grant permission in System Settings.
