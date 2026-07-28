import SwiftUI

struct RecordingListView: View {
    @Environment(RecordingStore.self) private var store
    @Environment(AudioRecorder.self) private var audioRecorder
    @Environment(TranscriptionService.self) private var transcriptionService
    @Environment(CloudSyncManager.self) private var cloudSync
    @Binding var selectedRecordingID: UUID?
    @Binding var showGlobalChat: Bool
    @State private var searchQuery = ""
    @State private var renamingRecordingID: UUID? = nil
    @State private var renameText = ""
    @State private var collapsedCategories: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: "collapsedCategories") ?? [])
    @State private var newCategorySheet: NewCategoryTarget? = nil
    @State private var renamingCategory: String? = nil
    @State private var combineSeed: CombineTarget? = nil

    /// Sheet payload: which recordings the combine sheet opens with.
    struct CombineTarget: Identifiable {
        let id = UUID()
        let recordingIDs: [UUID]
    }

    /// Sheet payload: the recording to move into the newly created category
    /// (nil id = just create).
    struct NewCategoryTarget: Identifiable {
        let id = UUID()
        let recordingID: UUID?
    }

    private static let uncategorizedKey = "__uncategorized__"

    private var filteredRecordings: [Recording] {
        guard !searchQuery.isEmpty else { return store.recordings }
        let lowered = searchQuery.lowercased()
        return store.recordings.filter { recording in
            if recording.displayName.lowercased().contains(lowered) { return true }
            if let url = recording.transcriptionURL,
               let content = try? String(contentsOf: url, encoding: .utf8),
               content.lowercased().contains(lowered) { return true }
            return false
        }
    }

    private func recordings(in category: String?) -> [Recording] {
        store.recordings.filter { $0.category == category }
    }

    var body: some View {
        List(selection: $selectedRecordingID) {
            Section {
                RecordingControlRow(onShowRecordingScreen: {
                    selectedRecordingID = nil
                    showGlobalChat = false
                })
                ImportAudioRow()
                if store.recordings.count >= 2 {
                    CombineRecordingsRow {
                        combineSeed = CombineTarget(recordingIDs: [])
                    }
                }
                GlobalChatRow(showGlobalChat: $showGlobalChat, selectedRecordingID: $selectedRecordingID)
            }

            if !searchQuery.isEmpty {
                // Search: flat results across all categories (existing behavior)
                Section {
                    if filteredRecordings.isEmpty {
                        emptyPlaceholder
                    } else {
                        recordingRows(filteredRecordings)
                    }
                } header: {
                    HStack {
                        Text("Results")
                        Spacer()
                        Text("\(filteredRecordings.count)")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                }
            } else if store.categories.isEmpty && recordings(in: nil).count == store.recordings.count {
                // No categories in use: single flat section (classic layout)
                Section {
                    if store.recordings.isEmpty {
                        emptyPlaceholder
                    } else {
                        recordingRows(store.recordings)
                    }
                } header: {
                    HStack {
                        Text("Recordings")
                        Spacer()
                        Text("\(store.recordings.count)")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                        newCategoryHeaderButton
                    }
                }
            } else {
                // Categorized: one collapsible section per category + Uncategorized
                ForEach(store.categories, id: \.self) { category in
                    Section(isExpanded: expansionBinding(for: category)) {
                        recordingRows(recordings(in: category))
                    } header: {
                        categoryHeader(category, count: recordings(in: category).count)
                    }
                }

                let uncategorized = recordings(in: nil)
                if !uncategorized.isEmpty {
                    Section(isExpanded: expansionBinding(for: Self.uncategorizedKey)) {
                        recordingRows(uncategorized)
                    } header: {
                        HStack {
                            Text("Uncategorized")
                            Spacer()
                            Text("\(uncategorized.count)")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.tertiary)
                                .monospacedDigit()
                            newCategoryHeaderButton
                        }
                    }
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
                store.update(recordingID) { $0.name = newName.isEmpty ? nil : newName }
            }
        }
        .sheet(item: $newCategorySheet) { target in
            CategoryNameSheet(title: "New Category", initialName: "") { name in
                store.addCategory(name)
                if let recordingID = target.recordingID {
                    store.update(recordingID) { $0.category = name }
                }
            }
        }
        .sheet(item: $renamingCategory) { category in
            CategoryNameSheet(title: "Rename Category", initialName: category) { name in
                store.renameCategory(category, to: name)
            }
        }
        .sheet(item: $combineSeed) { target in
            CombineRecordingsSheet(initialSelection: target.recordingIDs)
        }
        .onChange(of: selectedRecordingID) { _, newValue in
            if newValue != nil { showGlobalChat = false }
        }
    }

    private var emptyPlaceholder: some View {
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
    }

    private var newCategoryHeaderButton: some View {
        Button(action: { newCategorySheet = NewCategoryTarget(recordingID: nil) }) {
            Image(systemName: "folder.badge.plus")
                .font(.caption)
        }
        .buttonStyle(.plain)
        .help("New Category")
    }

    private func categoryHeader(_ category: String, count: Int) -> some View {
        HStack {
            Text(category)
            Spacer()
            Text("\(count)")
                .font(.caption.weight(.medium))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .contextMenu {
            Button("Rename Category…") { renamingCategory = category }
            Button("Delete Category", role: .destructive) {
                store.deleteCategory(category)
            }
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func recordingRows(_ recordings: [Recording]) -> some View {
        ForEach(recordings) { recording in
            RecordingRow(recording: recording)
                .tag(recording.id)
                .contextMenu { rowContextMenu(recording) }
        }
    }

    @ViewBuilder
    private func rowContextMenu(_ recording: Recording) -> some View {
        Button {
            if case .placeholder = cloudSync.state(for: recording) {
                cloudSync.requestDownload(recording)
                store.infoMessage = "Downloading “\(recording.displayName)” from iCloud — it will be playable in a moment."
            } else {
                audioRecorder.playRecording(recording)
            }
        } label: {
            Label("Play", systemImage: "play.fill")
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
                    Label("Remove Download (keep in iCloud)", systemImage: "xmark.icloud")
                }
            default:
                EmptyView()
            }
        }

        Menu {
            Button("On-Device (Local)") {
                transcriptionService.enqueue(recording.id, using: .local)
            }
            Button("OpenAI") {
                transcriptionService.enqueue(recording.id, using: .openAI)
            }
            .disabled(!KeychainStore.shared.has(.openAI))
            Button("AssemblyAI") {
                transcriptionService.enqueue(recording.id, using: .assemblyAI)
            }
            .disabled(!KeychainStore.shared.has(.assemblyAI))
        } label: {
            Label(recording.status.isResumable ? "Resume Transcription" : "Transcribe",
                  systemImage: "waveform.badge.mic")
        }
        .disabled(!recording.status.canStartTranscription)

        Button {
            renamingRecordingID = recording.id
            renameText = recording.name ?? ""
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
            if !store.categories.isEmpty {
                Divider()
            }
            Button {
                store.update(recording.id) { $0.category = nil }
            } label: {
                if recording.category == nil {
                    Label("Uncategorized", systemImage: "checkmark")
                } else {
                    Text("Uncategorized")
                }
            }
            Divider()
            Button("New Category…") {
                newCategorySheet = NewCategoryTarget(recordingID: recording.id)
            }
        } label: {
            Label("Move to", systemImage: "folder")
        }

        Button {
            store.showInFinder(recording)
        } label: {
            Label("Show in Finder", systemImage: "folder")
        }

        if RecordingStore.compressibleExtensions.contains(recording.fileURL.pathExtension.lowercased()) {
            Menu {
                Button {
                    Task { await store.compressAudio(recording, spec: .storage) }
                } label: {
                    Text("High Quality — 96 kbps (\(compressEstimate(.storage, for: recording)))")
                }
                Button {
                    Task { await store.compressAudio(recording, spec: .storageCompact) }
                } label: {
                    Text("Compact — 48 kbps (\(compressEstimate(.storageCompact, for: recording)))")
                }
            } label: {
                Label("Compress Audio (AAC)", systemImage: "arrow.down.circle")
            }
            .disabled(recording.status == .processing || store.compressingIDs.contains(recording.id))
        }

        Button {
            Task { await store.trimTrailingSilence(recording) }
        } label: {
            Label("Trim Silent Ending", systemImage: "scissors")
        }
        .disabled(recording.status == .processing || store.trimmingIDs.contains(recording.id))
        .help("Removes the stretch at the end where nothing was captured, keeping 15 seconds of margin.")

        Button {
            combineSeed = CombineTarget(recordingIDs: [recording.id])
        } label: {
            Label("Combine with…", systemImage: "arrow.trianglehead.merge")
        }
        .disabled(store.recordings.count < 2)
        .help("Join this recording with others into one file, in an order you choose.")

        Divider()

        Button(role: .destructive) {
            if selectedRecordingID == recording.id {
                selectedRecordingID = nil
            }
            if audioRecorder.playingRecordingID == recording.id {
                audioRecorder.stopPlayback()
            }
            store.delete(recording)
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    private func compressEstimate(_ spec: AudioCompressor.Spec, for recording: Recording) -> String {
        let bytes = Int64(spec.estimatedBytes(forSeconds: recording.duration))
        return "~" + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: - Expansion persistence

    /// Sections default to expanded; only explicit collapses are remembered.
    private func expansionBinding(for key: String) -> Binding<Bool> {
        Binding(
            get: { !collapsedCategories.contains(key) },
            set: { expanded in
                if expanded { collapsedCategories.remove(key) } else { collapsedCategories.insert(key) }
                UserDefaults.standard.set(Array(collapsedCategories), forKey: "collapsedCategories")
            }
        )
    }
}

// MARK: - Category Name Sheet

struct CategoryNameSheet: View {
    let title: String
    let initialName: String
    let onSave: (String) -> Void
    @State private var name = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text(title)
                .font(.headline)
            TextField("Category name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .onSubmit { save() }
            HStack(spacing: 12) {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.accent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .onAppear { name = initialName }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSave(trimmed)
        dismiss()
    }
}

// MARK: - Recording Row

struct RecordingRow: View {
    let recording: Recording
    @Environment(RecordingStore.self) private var store
    @Environment(AudioRecorder.self) private var audioRecorder
    @Environment(TranscriptionService.self) private var transcriptionService

    private var isPlayingThis: Bool {
        audioRecorder.isPlaying && audioRecorder.playingRecordingID == recording.id
    }

    private var progressLabel: String {
        if transcriptionService.isActive(recording.id) {
            let pct = Int(transcriptionService.progressPercent * 100)
            return pct > 0 ? "\(pct)%" : "Processing"
        }
        if let position = transcriptionService.queuePosition(of: recording.id) {
            return "#\(position)"
        }
        return "Queued"
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

                    CloudSyncBadge(recording: recording)

                    if let progress = store.compressingProgress[recording.id] {
                        HStack(spacing: 4) {
                            ProgressView(value: progress)
                                .progressViewStyle(.linear)
                                .frame(width: 44)
                            Text("\(Int(progress * 100))%")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(AppTheme.processing)
                        }
                        .help("Compressing audio…")
                    } else {
                        Text(recording.formatAndSizeLabel)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }

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
        case .paused:
            Label("Paused", systemImage: "pause.circle.fill")
                .font(.caption2)
                .foregroundStyle(AppTheme.warning)
                .labelStyle(.iconOnly)
        case .partial:
            Label("Partial", systemImage: "arrow.trianglehead.clockwise.rotate.90")
                .font(.caption2)
                .foregroundStyle(AppTheme.warning)
                .labelStyle(.iconOnly)
        }
    }
}

// MARK: - Record Row

struct RecordingControlRow: View {
    @Environment(AudioRecorder.self) private var audioRecorder
    var onShowRecordingScreen: (() -> Void)?

    var body: some View {
        Button(action: {
            if audioRecorder.isRecording {
                audioRecorder.stopRecording()
            } else {
                onShowRecordingScreen?()
            }
        }) {
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
                if audioRecorder.isRecording {
                    Text(Self.timerText(audioRecorder.recordingDuration))
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(AppTheme.recording)
                }
            }
        }
        .buttonStyle(.plain)
    }

    static func timerText(_ duration: TimeInterval) -> String {
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        let seconds = Int(duration) % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, seconds) }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Import Row

struct ImportAudioRow: View {
    @Environment(RecordingStore.self) private var store

    var body: some View {
        Button(action: { store.importAudioFiles() }) {
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

// MARK: - Combine Recordings Row

struct CombineRecordingsRow: View {
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(AppTheme.warning.opacity(0.15))
                        .frame(width: 28, height: 28)
                    Image(systemName: "arrow.trianglehead.merge")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(AppTheme.warning)
                }
                Text("Combine Recordings")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.warning)
            }
        }
        .buttonStyle(.plain)
        .help("Join several recordings into one, in an order you choose.")
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
