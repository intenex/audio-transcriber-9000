import SwiftUI
import AppKit

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            StorageSettingsTab()
                .tabItem { Label("Storage", systemImage: "folder") }
            AISettingsTab()
                .tabItem { Label("AI", systemImage: "cpu.fill") }
        }
        .frame(width: 460, height: 380)
    }
}

// MARK: - General Tab

struct GeneralSettingsTab: View {
    @AppStorage("huggingFaceToken") private var hfToken = ""
    @AppStorage("whisperModel") private var whisperModel = "large-v3"

    private let models = ["tiny", "base", "small", "medium", "large-v2", "large-v3"]

    var body: some View {
        Form {
            Section {
                SecureField("Paste your token here", text: $hfToken)
                    .textContentType(.password)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Required for speaker diarization (identifying who said what).")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 4) {
                        Image(systemName: "info.circle")
                            .font(.caption2)
                        Text("Get a token at huggingface.co/settings/tokens, then accept model terms at:")
                            .font(.caption)
                    }
                    .foregroundStyle(.tertiary)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("pyannote/speaker-diarization-community-1")
                        Text("pyannote/segmentation-3.0")
                    }
                    .font(.caption.monospaced())
                    .foregroundStyle(AppTheme.accent)
                }
            } header: {
                Label("HuggingFace Token", systemImage: "key.fill")
            }

            Section {
                Picker("Model", selection: $whisperModel) {
                    ForEach(models, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
                .pickerStyle(.menu)

                Text("Larger models are more accurate but slower. large-v3 is recommended for 64GB+ RAM.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label("Whisper Model", systemImage: "cpu")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Storage Tab

struct StorageSettingsTab: View {
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

                Text("Where new recordings and imported audio files are saved.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label("Storage Location", systemImage: "folder.fill")
            }

            Section {
                Button("Open Storage Folder") {
                    let path = storageDirectory.isEmpty
                        ? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                            .appendingPathComponent("AudioTranscriber").path
                        : storageDirectory
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
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

// MARK: - AI Tab

struct AISettingsTab: View {
    @Environment(LLMService.self) private var llmService
    @AppStorage("llmModel") private var selectedModel = "mlx-community/Mistral-7B-Instruct-v0.3-4bit"

    var body: some View {
        Form {
            Section {
                HStack(spacing: 8) {
                    Circle()
                        .fill(llmService.isAvailable ? AppTheme.success : AppTheme.recording)
                        .frame(width: 10, height: 10)
                    Text(llmService.isAvailable ? "Available" : "Not Available")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(llmService.isAvailable ? AppTheme.success : .secondary)
                    Spacer()
                    Button(llmService.isChecking ? "Checking..." : "Check") {
                        Task { await llmService.checkAvailability() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(llmService.isChecking)
                }

                if !llmService.isAvailable {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("mlx-lm is required for AI features (summarization, chat, smart search).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Install:")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Text("conda run -n transcriber pip install mlx-lm")
                            .font(.caption.monospaced())
                            .foregroundStyle(AppTheme.accent)
                            .textSelection(.enabled)
                        Text("The model downloads automatically (~4GB) on first use.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            } header: {
                Label("mlx-lm Status", systemImage: "cpu.fill")
            }

            Section {
                TextField("Model", text: $selectedModel)
                    .font(.subheadline.monospaced())
                Text("Default: mlx-community/Mistral-7B-Instruct-v0.3-4bit (~4GB)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Text("Browse models at huggingface.co/mlx-community")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } header: {
                Label("Model", systemImage: "cpu")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            Task { await llmService.checkAvailability() }
        }
    }
}
