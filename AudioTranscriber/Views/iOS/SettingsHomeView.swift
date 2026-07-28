#if os(iOS)
import Network
import SwiftUI

/// iPhone settings: the same UserDefaults/Keychain surface as the Mac tabs,
/// reorganized as one grouped form. No local-MLX section (Mac-only) and no
/// custom storage directory (iOS is sandboxed to Documents).
struct SettingsHomeView: View {
    @Environment(RecordingStore.self) private var store
    @Environment(ChatService.self) private var chatService
    @Environment(ModelManager.self) private var modelManager
    @Environment(SpeakerLibraryStore.self) private var speakerLibrary

    @AppStorage("defaultTranscriptionEngine") private var defaultEngine = TranscriptionEngineKind.local.rawValue
    @AppStorage("confirmCloudTranscription") private var confirmCloud = true
    @AppStorage("autoSummarize") private var autoSummarize = true
    @AppStorage("autoTranscribeNewRecordings") private var autoTranscribe = true
    @AppStorage("autoTrimTrailingSilence") private var autoTrimSilence = false
    @AppStorage("liveTranscriptionPreview") private var livePreview = true
    @AppStorage("chatProviderID") private var selectedProvider = ""
    @AppStorage("miniMaxModel") private var miniMaxModel = "MiniMax-M3"
    @AppStorage("openAIChatModel") private var openAIChatModel = "gpt-4o-mini"
    @AppStorage("customChatBaseURL") private var customBaseURL = ""
    @AppStorage("customChatModel") private var customModel = ""
    @AppStorage("recordingFormat") private var recordingFormat = RecordingFormat.aacHigh.rawValue
    @AppStorage("importCompression") private var importCompression = "ask"

    @State private var isDownloadingModels = false
    @State private var isPruning = false
    @State private var pruneResult: Int? = nil
    @State private var isOnExpensiveNetwork = false

    var body: some View {
        Form {
            Section("Transcription") {
                Picker("Default engine", selection: $defaultEngine) {
                    ForEach(TranscriptionEngineKind.allCases) { kind in
                        Text(kind.displayName).tag(kind.rawValue)
                    }
                }
                Toggle("Confirm before cloud transcription", isOn: $confirmCloud)
                Toggle("Auto-transcribe new recordings", isOn: $autoTranscribe)
                Toggle("Generate summary after transcription", isOn: $autoSummarize)
                Toggle("Live transcript preview while recording", isOn: $livePreview)
                Toggle("Trim silent endings", isOn: $autoTrimSilence)
                Text("New recordings lose the stretch at the end where nothing was captured (15 s of margin kept). Any recording can also be trimmed from its context menu.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Status", value: modelManager.summaryText)
                if !modelManager.allReady {
                    Button {
                        isDownloadingModels = true
                        Task {
                            await modelManager.downloadAll()
                            isDownloadingModels = false
                        }
                    } label: {
                        if isDownloadingModels {
                            HStack {
                                ProgressView().controlSize(.small)
                                Text("Downloading models…")
                            }
                        } else {
                            Text("Download On-Device Models")
                        }
                    }
                    .disabled(isDownloadingModels)
                }
            } header: {
                Text("On-Device Models")
            } footer: {
                Text(isOnExpensiveNetwork
                     ? "≈1.5 GB one-time download. You appear to be on cellular — Wi-Fi is strongly recommended."
                     : "≈1.5 GB one-time download for on-device transcription with speaker detection.")
            }

            Section("Cloud Transcription Keys") {
                KeychainSecureField(label: "OpenAI API Key", key: .openAI, prompt: "OpenAI key (sk-…)")
                KeychainSecureField(label: "AssemblyAI API Key", key: .assemblyAI, prompt: "AssemblyAI key")
            }

            Section {
                Picker("Provider", selection: $selectedProvider) {
                    Text("Automatic").tag("")
                    ForEach(ChatProviderID.allCases.filter { $0 != .localMLX }) { id in
                        Text(id.displayName).tag(id.rawValue)
                    }
                }
                KeychainSecureField(label: "MiniMax API Key", key: .miniMax, prompt: "MiniMax key")
                TextField("MiniMax model", text: $miniMaxModel)
                    .font(.subheadline.monospaced())
                TextField("OpenAI chat model", text: $openAIChatModel)
                    .font(.subheadline.monospaced())
            } header: {
                Text("AI Chat")
            } footer: {
                Text("Automatic uses MiniMax when its key is set, then OpenAI. Powers chat, summaries, and auto-naming. (The local MLX model is Mac-only.)")
            }

            Section("Custom Endpoint") {
                TextField("Base URL", text: $customBaseURL, prompt: Text("https://api.example.com/v1"))
                    .font(.subheadline.monospaced())
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                KeychainSecureField(label: "API Key", key: .custom, prompt: "API key")
                TextField("Model", text: $customModel, prompt: Text("model-name"))
                    .font(.subheadline.monospaced())
            }

            Section {
                if speakerLibrary.speakers.isEmpty {
                    Text("No enrolled voices yet. Rename a speaker in a transcript and keep “Remember this voice” on.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(speakerLibrary.speakers, id: \.id) { speaker in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(speaker.name)
                            Text("\(speaker.recordingIDs.count) recording\(speaker.recordingIDs.count == 1 ? "" : "s") · \(speaker.clips.count) clip\(speaker.clips.count == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                speakerLibrary.delete(speaker)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
                Button {
                    isPruning = true
                    Task {
                        pruneResult = await speakerLibrary.pruneSilentClips()
                        isPruning = false
                    }
                } label: {
                    if isPruning {
                        HStack { ProgressView().controlSize(.small); Text("Checking clips…") }
                    } else {
                        Text("Clean Up Silent Clips")
                    }
                }
                .disabled(isPruning || speakerLibrary.speakers.isEmpty)
                if let pruned = pruneResult {
                    Text(pruned == 0 ? "No silent clips found." : "Removed \(pruned) silent clip\(pruned == 1 ? "" : "s").")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Speaker Voices")
            } footer: {
                Text("Voices are matched on-device. Clips are only sent to a cloud engine when you choose one for transcription.")
            }

            CloudSyncSection()

            Section {
                Picker("Recording format", selection: $recordingFormat) {
                    ForEach(RecordingFormat.allCases, id: \.rawValue) { format in
                        Text(format.displayName).tag(format.rawValue)
                    }
                }
                .pickerStyle(.navigationLink)
                Picker("Compress imports", selection: $importCompression) {
                    Text("Ask each time").tag("ask")
                    Text("Always").tag("always")
                    Text("Never").tag("never")
                }
            } header: {
                Text("Storage")
            } footer: {
                Text("Library size: \(libraryLabel)")
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            modelManager.refreshStatus()
            checkNetwork()
        }
    }

    private var libraryLabel: String {
        let bytes = store.recordings.reduce(Int64(0)) { $0 + ($1.fileSizeBytes ?? 0) }
        return "\(store.recordings.count) recording\(store.recordings.count == 1 ? "" : "s") · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"
    }

    private func checkNetwork() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            DispatchQueue.main.async {
                isOnExpensiveNetwork = path.isExpensive
                monitor.cancel()
            }
        }
        monitor.start(queue: .global(qos: .utility))
    }
}
#endif
