import SwiftUI
import AppKit

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            TranscriptionSettingsTab()
                .tabItem { Label("Transcription", systemImage: "waveform.badge.mic") }
            AIChatSettingsTab()
                .tabItem { Label("AI Chat", systemImage: "bubble.left.and.bubble.right") }
            SpeakersSettingsTab()
                .tabItem { Label("Speakers", systemImage: "person.wave.2") }
            StorageSettingsTab()
                .tabItem { Label("Storage", systemImage: "folder") }
        }
        .frame(width: 560, height: 480)
    }
}

// MARK: - Keychain-backed secure field

struct KeychainSecureField: View {
    let label: String
    let key: SecretKey
    var prompt: String = "Paste your API key"

    @State private var value = ""
    @State private var isSaved = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            SecureField(prompt, text: $value)
                .textContentType(.password)
                .focused($focused)
                .onSubmit { save() }
            if isSaved && !value.isEmpty {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(AppTheme.success)
                    .help("Saved in Keychain")
            }
            if !value.isEmpty {
                Button(action: {
                    value = ""
                    KeychainStore.shared.delete(key)
                    isSaved = false
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Remove key")
            }
        }
        .onAppear {
            value = KeychainStore.shared.get(key) ?? ""
            isSaved = !value.isEmpty
        }
        .onChange(of: focused) { _, isFocused in
            if !isFocused { save() }
        }
    }

    private func save() {
        KeychainStore.shared.set(value, for: key)
        isSaved = KeychainStore.shared.has(key)
    }
}

// MARK: - General Tab

struct GeneralSettingsTab: View {
    @AppStorage("defaultTranscriptionEngine") private var defaultEngine = TranscriptionEngineKind.local.rawValue
    @AppStorage("confirmCloudTranscription") private var confirmCloud = true
    @AppStorage("autoSummarize") private var autoSummarize = true
    @AppStorage("autoTranscribeNewRecordings") private var autoTranscribe = false
    @AppStorage("liveTranscriptionPreview") private var livePreview = true

    var body: some View {
        Form {
            Section {
                Picker("Default engine", selection: $defaultEngine) {
                    ForEach(TranscriptionEngineKind.allCases) { kind in
                        Text(kind.displayName).tag(kind.rawValue)
                    }
                }
                Toggle("Confirm before cloud transcription (shows cost estimate)", isOn: $confirmCloud)
                Toggle("Automatically transcribe new recordings", isOn: $autoTranscribe)
            } header: {
                Label("Transcription", systemImage: "waveform.badge.mic")
            }

            Section {
                Toggle("Generate summary after transcription", isOn: $autoSummarize)
                Toggle("Live transcript preview while recording", isOn: $livePreview)
            } header: {
                Label("Behavior", systemImage: "sparkles")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Transcription Tab

struct TranscriptionSettingsTab: View {
    @Environment(ModelManager.self) private var modelManager

    var body: some View {
        Form {
            Section {
                HStack(spacing: 8) {
                    Circle()
                        .fill(modelManager.allReady ? AppTheme.success : AppTheme.warning)
                        .frame(width: 10, height: 10)
                    Text(modelManager.summaryText)
                        .font(.subheadline)
                    Spacer()
                    if !modelManager.allReady {
                        Button("Download") {
                            Task { await modelManager.downloadAll() }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(AppTheme.accent)
                        .disabled(isDownloading)
                    } else {
                        Button("Remove") { modelManager.removeAll() }
                            .buttonStyle(.bordered)
                    }
                }
                Text("Parakeet v3 speech recognition + pyannote speaker identification, running fully on-device via the Neural Engine. Free, private, and works offline once downloaded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label("On-Device Models", systemImage: "cpu")
            }

            Section {
                KeychainSecureField(label: "OpenAI API Key", key: .openAI, prompt: "sk-…")
                Text("Uses gpt-4o-transcribe-diarize (≈ $0.006/min). Audio is compressed to 16 kHz mono AAC before upload. Enrolled speaker voices are sent as reference clips so speakers are named automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label("OpenAI", systemImage: "key.fill")
            }

            Section {
                KeychainSecureField(label: "AssemblyAI API Key", key: .assemblyAI, prompt: "API key")
                Text("Best for very long recordings — files upload once (up to 5 GB) with no splitting. ≈ $0.005/min with speaker labels.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label("AssemblyAI", systemImage: "key.fill")
            }
        }
        .formStyle(.grouped)
        .onAppear { modelManager.refreshStatus() }
    }

    private var isDownloading: Bool {
        if case .downloading = modelManager.asrState { return true }
        if case .downloading = modelManager.diarizerState { return true }
        return false
    }
}

// MARK: - AI Chat Tab

struct AIChatSettingsTab: View {
    @Environment(ChatService.self) private var chatService
    @AppStorage("chatProviderID") private var selectedProvider = ""
    @AppStorage("miniMaxModel") private var miniMaxModel = "MiniMax-M2"
    @AppStorage("openAIChatModel") private var openAIChatModel = "gpt-4o-mini"
    @AppStorage("customChatBaseURL") private var customBaseURL = ""
    @AppStorage("customChatModel") private var customModel = ""
    @AppStorage("llmModel") private var localModel = "mlx-community/Mistral-7B-Instruct-v0.3-4bit"

    var body: some View {
        Form {
            Section {
                Picker("Provider", selection: $selectedProvider) {
                    Text("Automatic").tag("")
                    ForEach(ChatProviderID.allCases) { id in
                        Text(id.displayName).tag(id.rawValue)
                    }
                }
                Text("Automatic uses MiniMax when its key is set, then OpenAI, then the local model. Powers chat, summaries, and auto-naming.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label("Chat Provider", systemImage: "bubble.left.and.bubble.right")
            }

            Section {
                KeychainSecureField(label: "MiniMax API Key", key: .miniMax)
                TextField("Model", text: $miniMaxModel)
                    .font(.subheadline.monospaced())
                Text("International endpoint (api.minimax.io).")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } header: {
                Label("MiniMax", systemImage: "key.fill")
            }

            Section {
                TextField("Model", text: $openAIChatModel)
                    .font(.subheadline.monospaced())
                Text("Uses the OpenAI API key from the Transcription tab.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } header: {
                Label("OpenAI", systemImage: "key.fill")
            }

            Section {
                TextField("Base URL", text: $customBaseURL, prompt: Text("https://api.example.com/v1"))
                    .font(.subheadline.monospaced())
                KeychainSecureField(label: "API Key", key: .custom)
                TextField("Model", text: $customModel, prompt: Text("model-name"))
                    .font(.subheadline.monospaced())
                Text("Any OpenAI-compatible chat completions endpoint.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } header: {
                Label("Custom Endpoint", systemImage: "network")
            }

            Section {
                HStack(spacing: 8) {
                    Circle()
                        .fill(chatService.isLocalMLXAvailable ? AppTheme.success : AppTheme.recording)
                        .frame(width: 10, height: 10)
                    Text(chatService.isLocalMLXAvailable ? "Available" : "Not available")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Button(chatService.isCheckingLocal ? "Checking…" : "Check") {
                        Task { await chatService.checkLocalAvailability() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(chatService.isCheckingLocal)
                }
                TextField("Model", text: $localModel)
                    .font(.subheadline.monospaced())
                if !chatService.isLocalMLXAvailable {
                    Text("Install with: conda run -n transcriber pip install mlx-lm")
                        .font(.caption.monospaced())
                        .foregroundStyle(AppTheme.accent)
                        .textSelection(.enabled)
                }
            } header: {
                Label("Local (MLX)", systemImage: "cpu.fill")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            Task { await chatService.checkLocalAvailability() }
        }
    }
}

// MARK: - Speakers Tab

struct SpeakersSettingsTab: View {
    @Environment(SpeakerLibraryStore.self) private var speakerLibrary
    @State private var playingClipURL: URL? = nil
    @State private var clipPlayer = ClipPlayer()

    var body: some View {
        Form {
            Section {
                if speakerLibrary.speakers.isEmpty {
                    Text("No voices enrolled yet. Name a speaker in any transcript and leave “Remember this voice” on — they'll be recognized automatically in future recordings.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(speakerLibrary.speakers) { speaker in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(speaker.name)
                                    .font(.subheadline.weight(.medium))
                                Text("Seen in \(speaker.recordingIDs.count) recording\(speaker.recordingIDs.count == 1 ? "" : "s") · \(speaker.clips.count) voice clip\(speaker.clips.count == 1 ? "" : "s")")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                            if let clip = speaker.clips.first {
                                Button(action: { clipPlayer.togglePlay(url: speakerLibrary.clipURL(for: clip)) }) {
                                    Image(systemName: "play.circle")
                                }
                                .buttonStyle(.plain)
                                .help("Play voice sample")
                            }
                            Button(role: .destructive, action: { speakerLibrary.delete(speaker) }) {
                                Image(systemName: "trash")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Forget this voice")
                        }
                    }
                }
            } header: {
                Label("Enrolled Voices", systemImage: "person.wave.2")
            }

            Section {
                LabeledContent("Match sensitivity") {
                    Slider(value: matchThresholdBinding, in: 0.5...0.9, step: 0.05)
                        .frame(width: 200)
                }
                Text("Threshold \(String(format: "%.2f", speakerLibrary.autoMatchThreshold)) — higher requires a closer voice match before auto-naming a speaker.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } header: {
                Label("Recognition", systemImage: "waveform.and.person.filled")
            }

            Section {
                Text("Voice profiles are stored only on this Mac. Reference clips are sent to a cloud provider only when you choose that provider for transcription, to label speakers automatically.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
    }

    private var matchThresholdBinding: Binding<Double> {
        Binding(
            get: { Double(speakerLibrary.autoMatchThreshold) },
            set: { speakerLibrary.autoMatchThreshold = Float($0) }
        )
    }
}

/// Tiny standalone player for voice-clip previews in Settings.
import AVFoundation
@Observable
final class ClipPlayer {
    private var player: AVAudioPlayer? = nil

    func togglePlay(url: URL) {
        if let player, player.isPlaying {
            player.stop()
            self.player = nil
            return
        }
        player = try? AVAudioPlayer(contentsOf: url)
        player?.play()
    }
}

// MARK: - Storage Tab

struct StorageSettingsTab: View {
    @Environment(RecordingStore.self) private var store
    @AppStorage("storageDirectory") private var storageDirectory = ""

    var body: some View {
        Form {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(storageDirectoryDisplay)
                            .font(.subheadline)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if storageDirectory.isEmpty {
                            Text("Default: ~/Documents/AudioTranscriber")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Spacer()
                    Button("Choose...") { chooseStorageDirectory() }
                        .buttonStyle(.bordered)
                    if !storageDirectory.isEmpty {
                        Button(action: { storageDirectory = "" }) {
                            Image(systemName: "arrow.uturn.backward")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .help("Reset to default")
                    }
                }

                Text("Where new recordings and imported audio files are saved. Changing this switches to the library in that folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label("Storage Location", systemImage: "folder.fill")
            }
            .onChange(of: storageDirectory) { _, _ in
                store.reloadFromStorageDirectory()
            }

            Section {
                Button("Open Storage Folder") {
                    NSWorkspace.shared.open(store.storageDirectory)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var storageDirectoryDisplay: String {
        if storageDirectory.isEmpty {
            return "Default Location"
        }
        return (storageDirectory as NSString).abbreviatingWithTildeInPath
    }

    private func chooseStorageDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose where to save recordings"
        if panel.runModal() == .OK, let url = panel.url {
            storageDirectory = url.path
        }
    }
}
