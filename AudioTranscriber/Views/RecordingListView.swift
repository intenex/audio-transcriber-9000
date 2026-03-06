import SwiftUI

struct RecordingListView: View {
    @Environment(AudioRecorder.self) private var audioRecorder
    @Environment(TranscriptionService.self) private var transcriptionService
    @Binding var selectedRecordingID: UUID?
    @Binding var showGlobalChat: Bool
    @State private var searchQuery = ""
    @State private var renamingRecordingID: UUID? = nil
    @State private var renameText = ""

    private var filteredRecordings: [Recording] {
        guard !searchQuery.isEmpty else { return audioRecorder.recordings }
        let lowered = searchQuery.lowercased()
        return audioRecorder.recordings.filter { recording in
            if recording.displayName.lowercased().contains(lowered) { return true }
            if let url = recording.transcriptionURL,
               let content = try? String(contentsOf: url, encoding: .utf8),
               content.lowercased().contains(lowered) { return true }
            return false
        }
    }

    var body: some View {
        List(selection: $selectedRecordingID) {
            Section {
                RecordingControlRow()
                ImportAudioRow()
                GlobalChatRow(showGlobalChat: $showGlobalChat, selectedRecordingID: $selectedRecordingID)
            }

            Section {
                if filteredRecordings.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: searchQuery.isEmpty ? "waveform.slash" : "magnifyingglass")
                            .font(.title2)
                            .foregroundStyle(.quaternary)
                        Text(searchQuery.isEmpty ? "No recordings yet" : "No matches")
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                } else {
                    ForEach(filteredRecordings) { recording in
                        RecordingRow(recording: recording)
                            .tag(recording.id)
                            .contextMenu {
                                Button {
                                    audioRecorder.playRecording(recording)
                                } label: {
                                    Label("Play", systemImage: "play.fill")
                                }

                                Button {
                                    Task { await transcribe(recording) }
                                } label: {
                                    Label("Transcribe", systemImage: "waveform.badge.mic")
                                }
                                .disabled(recording.status == .processing)

                                Button {
                                    renamingRecordingID = recording.id
                                    renameText = recording.name ?? ""
                                } label: {
                                    Label("Rename", systemImage: "pencil")
                                }

                                Button {
                                    audioRecorder.showInFinder(recording)
                                } label: {
                                    Label("Show in Finder", systemImage: "folder")
                                }

                                Divider()

                                Button(role: .destructive) {
                                    if selectedRecordingID == recording.id {
                                        selectedRecordingID = nil
                                    }
                                    audioRecorder.deleteRecording(recording)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                }
            } header: {
                HStack {
                    Text("Recordings")
                    Spacer()
                    Text("\(filteredRecordings.count)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $searchQuery, placement: .sidebar, prompt: "Search recordings")
        .frame(minWidth: 240, idealWidth: 280)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        }
        .safeAreaInset(edge: .top) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.badge.mic")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(AppTheme.accent)
                Text("AT-9000")
                    .font(.headline)
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .sheet(item: $renamingRecordingID) { recordingID in
            RenameSheet(recordingID: recordingID, initialName: renameText) { newName in
                if let idx = audioRecorder.recordings.firstIndex(where: { $0.id == recordingID }) {
                    audioRecorder.recordings[idx].name = newName.isEmpty ? nil : newName
                    audioRecorder.saveRecordings()
                }
            }
        }
        .onChange(of: selectedRecordingID) { _, newValue in
            if newValue != nil { showGlobalChat = false }
        }
    }

    private func transcribe(_ recording: Recording) async {
        var mutable = recording
        await transcriptionService.transcribe(recording: &mutable)
        if let idx = audioRecorder.recordings.firstIndex(where: { $0.id == mutable.id }) {
            audioRecorder.recordings[idx] = mutable
        }
    }
}

// Make UUID conform to Identifiable for .sheet(item:)
extension UUID: @retroactive Identifiable {
    public var id: UUID { self }
}

// MARK: - Recording Row

struct RecordingRow: View {
    let recording: Recording
    @Environment(AudioRecorder.self) private var audioRecorder
    @Environment(TranscriptionService.self) private var transcriptionService

    private var isPlayingThis: Bool {
        audioRecorder.isPlaying && audioRecorder.playingRecordingID == recording.id
    }

    private var progressLabel: String {
        let pct = Int(transcriptionService.progressPercent * 100)
        return pct > 0 ? "\(pct)%" : "Processing"
    }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: { audioRecorder.playRecording(recording) }) {
                ZStack {
                    Circle()
                        .fill(isPlayingThis ? AppTheme.accent.opacity(0.15) : Color.clear)
                        .frame(width: 28, height: 28)
                    Image(systemName: isPlayingThis ? "stop.fill" : "play.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(isPlayingThis ? AppTheme.accent : .secondary)
                }
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 3) {
                Text(recording.displayName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(recording.formattedDate)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)

                    Text(recording.durationString)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary.opacity(0.5), in: Capsule())

                    statusBadge
                }
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch recording.status {
        case .pending:
            Label("Pending", systemImage: "clock")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .labelStyle(.iconOnly)
        case .processing:
            HStack(spacing: 4) {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 12, height: 12)
                Text(progressLabel)
                    .font(.caption2)
                    .foregroundStyle(AppTheme.processing)
            }
        case .done:
            Label("Done", systemImage: "checkmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(AppTheme.success)
                .labelStyle(.iconOnly)
        case .failed:
            Label("Failed", systemImage: "exclamationmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(AppTheme.recording)
                .labelStyle(.iconOnly)
        }
    }
}

// MARK: - Record Row

struct RecordingControlRow: View {
    @Environment(AudioRecorder.self) private var audioRecorder

    var body: some View {
        Button(action: toggleRecording) {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(audioRecorder.isRecording ? AppTheme.recording.opacity(0.15) : AppTheme.accent.opacity(0.15))
                        .frame(width: 28, height: 28)
                    Image(systemName: audioRecorder.isRecording ? "stop.fill" : "plus")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(audioRecorder.isRecording ? AppTheme.recording : AppTheme.accent)
                }
                Text(audioRecorder.isRecording ? "Stop Recording" : "New Recording")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(audioRecorder.isRecording ? AppTheme.recording : AppTheme.accent)
            }
        }
        .buttonStyle(.plain)
    }

    private func toggleRecording() {
        if audioRecorder.isRecording {
            audioRecorder.stopRecording()
        } else {
            audioRecorder.startRecording()
        }
    }
}

// MARK: - Import Row

struct ImportAudioRow: View {
    @Environment(AudioRecorder.self) private var audioRecorder

    var body: some View {
        Button(action: { audioRecorder.importAudioFiles() }) {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(AppTheme.processing.opacity(0.15))
                        .frame(width: 28, height: 28)
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(AppTheme.processing)
                }
                Text("Import Audio")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.processing)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Global Chat Row

struct GlobalChatRow: View {
    @Binding var showGlobalChat: Bool
    @Binding var selectedRecordingID: UUID?

    var body: some View {
        Button(action: {
            selectedRecordingID = nil
            showGlobalChat = true
        }) {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(AppTheme.success.opacity(0.15))
                        .frame(width: 28, height: 28)
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(AppTheme.success)
                }
                Text("Chat with All")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.success)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Rename Sheet

struct RenameSheet: View {
    let recordingID: UUID
    let initialName: String
    let onRename: (String) -> Void
    @State private var name = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text("Rename Recording")
                .font(.headline)
            TextField("Recording name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .onSubmit { save() }
            HStack(spacing: 12) {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.accent)
            }
        }
        .padding(24)
        .onAppear { name = initialName }
    }

    private func save() {
        onRename(name.trimmingCharacters(in: .whitespacesAndNewlines))
        dismiss()
    }
}
