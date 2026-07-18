#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers

/// iPhone home: searchable, category-sectioned library with import, global
/// chat, and per-recording actions. Pushes RecordingDetailView.
struct RecordingsHomeView: View {
    @Environment(RecordingStore.self) private var store
    @Environment(AudioRecorder.self) private var audioRecorder
    @Environment(TranscriptionService.self) private var transcriptionService
    @Environment(CloudSyncManager.self) private var cloudSync

    @State private var searchText = ""
    @State private var showingRecordSheet = false
    @State private var showingImporter = false
    @State private var pendingImportURLs: [URL] = []
    @State private var showingCompressDialog = false
    @State private var renamingRecording: Recording? = nil
    @State private var renameText = ""
    @State private var deletingRecording: Recording? = nil

    var body: some View {
        List {
            ForEach(sectionedRecordings, id: \.title) { section in
                Section {
                    ForEach(section.recordings) { recording in
                        NavigationLink(value: recording.id) {
                            HomeRecordingRow(recording: recording)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                deletingRecording = recording
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .contextMenu { rowMenu(for: recording) }
                    }
                } header: {
                    if let title = section.title {
                        Text(title)
                    }
                }
            }
        }
        .navigationTitle("Recordings")
        .navigationDestination(for: UUID.self) { id in
            if let recording = store.recording(with: id) {
                RecordingDetailView(recording: recording)
            } else {
                ContentUnavailableView("Recording Deleted", systemImage: "trash")
            }
        }
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic))
        .overlay {
            if store.recordings.isEmpty {
                ContentUnavailableView("No Recordings",
                                       systemImage: "waveform",
                                       description: Text("Tap Record, or import audio files."))
            } else if !searchText.isEmpty && sectionedRecordings.allSatisfy({ $0.recordings.isEmpty }) {
                ContentUnavailableView.search(text: searchText)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink {
                    ChatSessionView(context: .global)
                } label: {
                    Image(systemName: "bubble.left.and.bubble.right")
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    showingImporter = true
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                NavigationLink {
                    SettingsHomeView()
                } label: {
                    Image(systemName: "gearshape")
                }
            }
        }
        .safeAreaInset(edge: .bottom) { recordButton }
        .fullScreenCover(isPresented: $showingRecordSheet) { RecordSheet() }
        .fileImporter(isPresented: $showingImporter,
                      allowedContentTypes: [.audio],
                      allowsMultipleSelection: true) { result in
            handleImport(result)
        }
        .confirmationDialog("Compress imported audio?",
                            isPresented: $showingCompressDialog,
                            titleVisibility: .visible) {
            Button("Compress (\(compressDialogEstimate))") { runImport(compress: true) }
            Button("Keep Original Format") { runImport(compress: false) }
            Button("Cancel", role: .cancel) { endImportAccess() }
        } message: {
            Text("Quality remains excellent for listening and transcription. Originals are not modified.")
        }
        .alert("Rename Recording", isPresented: .constant(renamingRecording != nil)) {
            TextField("Name", text: $renameText)
            Button("Save") {
                if let recording = renamingRecording {
                    let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    store.update(recording.id) { $0.name = trimmed.isEmpty ? nil : trimmed }
                }
                renamingRecording = nil
            }
            Button("Cancel", role: .cancel) { renamingRecording = nil }
        }
        .alert("Delete Recording?", isPresented: .constant(deletingRecording != nil)) {
            Button("Delete", role: .destructive) {
                if let recording = deletingRecording {
                    audioRecorder.stopPlayback()
                    store.delete(recording)
                }
                deletingRecording = nil
            }
            Button("Cancel", role: .cancel) { deletingRecording = nil }
        } message: {
            Text("This will permanently delete the recording and its transcription.")
        }
    }

    // MARK: - Sections

    private struct RecordingSection {
        let title: String?
        let recordings: [Recording]
    }

    private var filteredRecordings: [Recording] {
        guard !searchText.isEmpty else { return store.recordings }
        let query = searchText.lowercased()
        return store.recordings.filter {
            $0.displayName.lowercased().contains(query)
                || ($0.category?.lowercased().contains(query) ?? false)
        }
    }

    private var sectionedRecordings: [RecordingSection] {
        let recordings = filteredRecordings
        guard !store.categories.isEmpty else {
            return [RecordingSection(title: nil, recordings: recordings)]
        }
        var sections: [RecordingSection] = []
        for category in store.categories {
            let members = recordings.filter { $0.category == category }
            if !members.isEmpty {
                sections.append(RecordingSection(title: category, recordings: members))
            }
        }
        let uncategorized = recordings.filter { $0.category == nil || !(store.categories.contains($0.category!)) }
        if !uncategorized.isEmpty {
            sections.append(RecordingSection(title: "Uncategorized", recordings: uncategorized))
        }
        return sections
    }

    // MARK: - Row actions

    @ViewBuilder
    private func rowMenu(for recording: Recording) -> some View {
        Button {
            if case .placeholder = cloudSync.state(for: recording) {
                cloudSync.requestDownload(recording)
                store.infoMessage = "Downloading “\(recording.displayName)” from iCloud — it will be playable in a moment."
            } else {
                audioRecorder.playRecording(recording)
            }
        } label: {
            let playingThis = audioRecorder.isPlaying && audioRecorder.playingRecordingID == recording.id
            Label(playingThis ? "Stop" : "Play", systemImage: playingThis ? "stop.fill" : "play.fill")
        }
        if cloudSync.isEnabled {
            switch cloudSync.state(for: recording) {
            case .placeholder:
                Button {
                    cloudSync.requestDownload(recording)
                } label: {
                    Label("Download from iCloud", systemImage: "icloud.and.arrow.down")
                }
            case .current:
                Button {
                    cloudSync.evictAudio(recording)
                } label: {
                    Label("Remove Download", systemImage: "xmark.icloud")
                }
            default:
                EmptyView()
            }
        }
        if recording.status.canStartTranscription {
            Menu {
                TranscribeEngineMenuItems(recording: recording) { kind in
                    transcriptionService.enqueue(recording.id, using: kind)
                }
            } label: {
                Label(recording.status.isResumable ? "Resume Transcription" : "Transcribe",
                      systemImage: "waveform.badge.mic")
            }
        }
        Button {
            renameText = recording.name ?? ""
            renamingRecording = recording
        } label: {
            Label("Rename", systemImage: "pencil")
        }
        Menu {
            ForEach(store.categories, id: \.self) { category in
                Button {
                    store.update(recording.id) { $0.category = category }
                } label: {
                    if recording.category == category {
                        Label(category, systemImage: "checkmark")
                    } else {
                        Text(category)
                    }
                }
            }
            if recording.category != nil {
                Divider()
                Button("Remove from Category") {
                    store.update(recording.id) { $0.category = nil }
                }
            }
        } label: {
            Label("Move To", systemImage: "folder")
        }
        if RecordingStore.compressibleExtensions.contains(recording.fileURL.pathExtension.lowercased()) {
            Button {
                Task { await store.compressAudio(recording) }
            } label: {
                Label("Compress Audio", systemImage: "archivebox")
            }
        }
        Divider()
        Button(role: .destructive) {
            deletingRecording = recording
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    private var recordButton: some View {
        Button {
            showingRecordSheet = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "record.circle")
                    .font(.body.weight(.semibold))
                Text("Record")
                    .font(.body.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(AppTheme.heroGradient)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: AppTheme.accent.opacity(0.3), radius: 8, y: 4)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }

    // MARK: - Import

    private var compressDialogEstimate: String {
        let estimate = store.importCompressionEstimate(for: pendingImportURLs)
        let before = ByteCountFormatter.string(fromByteCount: estimate.originalBytes, countStyle: .file)
        let after = ByteCountFormatter.string(fromByteCount: estimate.compressedBytes, countStyle: .file)
        return "\(before) → ~\(after)"
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, !urls.isEmpty else { return }
        // Keep security-scoped access alive until the copy finishes.
        pendingImportURLs = urls.filter { $0.startAccessingSecurityScopedResource() }
        let estimate = store.importCompressionEstimate(for: pendingImportURLs)
        switch store.resolveImportCompressionPolicy() {
        case .always: runImport(compress: true)
        case .never: runImport(compress: false)
        case .ask:
            if estimate.compressibleCount > 0 {
                showingCompressDialog = true
            } else {
                runImport(compress: false)
            }
        }
    }

    private func runImport(compress: Bool) {
        let urls = pendingImportURLs
        Task {
            await store.importAudioFiles(urls: urls, compress: compress).value
            for url in urls { url.stopAccessingSecurityScopedResource() }
        }
        pendingImportURLs = []
    }

    private func endImportAccess() {
        for url in pendingImportURLs { url.stopAccessingSecurityScopedResource() }
        pendingImportURLs = []
    }
}

struct HomeRecordingRow: View {
    let recording: Recording
    @Environment(RecordingStore.self) private var store
    @Environment(TranscriptionService.self) private var transcriptionService

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(recording.displayName)
                .font(.body)
                .lineLimit(1)
            HStack(spacing: 8) {
                Text(recording.formattedDate)
                Label(recording.durationString, systemImage: "clock")
                    .labelStyle(.titleOnly)
                Text(recording.formatAndSizeLabel)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                StatusPill(status: recording.status)
                CloudSyncBadge(recording: recording)
                if let progress = store.compressingProgress[recording.id] {
                    ProgressView(value: progress)
                        .frame(width: 80)
                }
                if transcriptionService.isActive(recording.id) {
                    Text(transcriptionService.progress)
                        .font(.caption2)
                        .foregroundStyle(AppTheme.processing)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
#endif
