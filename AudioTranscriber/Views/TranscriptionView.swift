import SwiftUI
import AppKit

enum DetailTab: String, CaseIterable {
    case transcript = "Transcript"
    case summary = "Summary"
    case chat = "Chat"
}

struct TranscriptionView: View {
    let recording: Recording
    @Environment(RecordingStore.self) private var store
    @Environment(TranscriptionService.self) private var transcriptionService
    @Environment(AudioRecorder.self) private var audioRecorder
    @Environment(ChatService.self) private var chatService

    @State private var markdownContent: String? = nil
    @State private var segments: [TranscriptionSegment]? = nil
    @State private var isLoading = false
    @State private var showingDeleteConfirm = false
    @State private var showCopiedToast = false
    @State private var selectedTab: DetailTab = .transcript
    @State private var isEditingName = false
    @State private var editName = ""
    @State private var loadedSummary: RecordingSummary? = nil
    @State private var isRegeneratingSummary = false
    @State private var transcriptSearchQuery = ""
    @State private var speakerNames: [String: String] = [:]
    @State private var editingSpeakerID: String? = nil
    @State private var editingSpeakerName: String = ""

    private var isPlayingThis: Bool {
        audioRecorder.isPlaying && audioRecorder.playingRecordingID == recording.id
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

            // Tab picker for completed recordings
            if recording.status == .done {
                Picker("View", selection: $selectedTab) {
                    ForEach(DetailTab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                Divider()
            }

            // Content
            Group {
                switch recording.status {
                case .pending, .paused, .partial:
                    pendingView
                case .processing:
                    processingView
                case .done:
                    switch selectedTab {
                    case .transcript:
                        if let segs = segments, !segs.isEmpty {
                            interactiveTranscriptContent(segs)
                        } else if let content = markdownContent {
                            transcriptTabContent(content)
                        } else {
                            ProgressView("Loading transcript...")
                        }
                    case .summary:
                        summaryTabContent
                    case .chat:
                        ChatSessionView(context: .recording(recording))
                    }
                case .failed:
                    failedView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay(alignment: .bottom) {
            if showCopiedToast {
                copiedToast
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onAppear { loadMarkdown() }
        .onChange(of: recording.status) { _, _ in loadMarkdown() }
        .onChange(of: recording.transcriptionURL) { _, _ in loadMarkdown() }
        .alert("Delete Recording?", isPresented: $showingDeleteConfirm) {
            Button("Delete", role: .destructive) {
                audioRecorder.stopPlayback()
                store.delete(recording)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete the recording and its transcription.")
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 14) {
            // Play button
            Button(action: { audioRecorder.playRecording(recording) }) {
                ZStack {
                    Circle()
                        .fill(isPlayingThis ? AppTheme.accent : AppTheme.accent.opacity(0.1))
                        .frame(width: 36, height: 36)
                    Image(systemName: isPlayingThis ? "stop.fill" : "play.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(isPlayingThis ? .white : AppTheme.accent)
                }
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                if isEditingName {
                    TextField("Recording name", text: $editName, onCommit: {
                        saveName()
                    })
                    .textFieldStyle(.roundedBorder)
                    .font(.headline)
                    .frame(maxWidth: 300)
                    .onExitCommand { isEditingName = false }
                } else {
                    Text(recording.displayName)
                        .font(.headline)
                        .onTapGesture {
                            editName = recording.name ?? ""
                            isEditingName = true
                        }
                }
                HStack(spacing: 8) {
                    if recording.name != nil {
                        Text(recording.formattedDate)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Label(recording.durationString, systemImage: "clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    statusPill
                }
            }

            Spacer()
            actionButtons
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    @ViewBuilder
    private var statusPill: some View {
        switch recording.status {
        case .done:
            Text("Transcribed")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(AppTheme.success)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(AppTheme.success.opacity(0.12), in: Capsule())
        case .processing:
            Text("Processing...")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(AppTheme.processing)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(AppTheme.processing.opacity(0.12), in: Capsule())
        case .failed:
            Text("Failed")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(AppTheme.recording)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(AppTheme.recording.opacity(0.12), in: Capsule())
        case .paused:
            Text("Paused")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(AppTheme.warning)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(AppTheme.warning.opacity(0.12), in: Capsule())
        case .partial:
            Text("Partially transcribed")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(AppTheme.warning)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(AppTheme.warning.opacity(0.12), in: Capsule())
        case .pending:
            EmptyView()
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        HStack(spacing: 8) {
            if recording.status == .done, markdownContent != nil {
                Button(action: {
                    let exportContent = exportableTranscript()
                    copyToClipboard(exportContent)
                    withAnimation(.spring(duration: 0.3)) { showCopiedToast = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        withAnimation { showCopiedToast = false }
                    }
                }) {
                    Label("Copy", systemImage: "doc.on.doc")
                        .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.bordered)
                .tint(AppTheme.accent)

                Menu {
                    Section("Transcript") {
                        Button(action: { exportTranscript() }) {
                            Label("Export Transcript (.md)", systemImage: "doc.text")
                        }
                    }

                    Section("Audio") {
                        Button(action: { exportAudio(format: .wav) }) {
                            Label("Export as WAV (\(audioSizeEstimate(format: .wav)))", systemImage: "waveform")
                        }
                        Button(action: { exportAudio(format: .mp3) }) {
                            Label("Export as MP3 (\(audioSizeEstimate(format: .mp3)))", systemImage: "waveform.badge.minus")
                        }
                    }

                    if loadedSummary != nil {
                        Section("Summary") {
                            Button(action: { exportSummary() }) {
                                Label("Export Summary (.md)", systemImage: "doc.text.magnifyingglass")
                            }
                        }
                    }

                    if hasChatHistory {
                        Section("Chat") {
                            Button(action: { exportChat() }) {
                                Label("Export Chat (.md)", systemImage: "bubble.left.and.bubble.right")
                            }
                        }
                    }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                        .font(.subheadline.weight(.medium))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            if recording.status.canStartTranscription {
                Button(action: { Task { await transcribeRecording() } }) {
                    Label(recording.status.isResumable ? "Resume" : "Transcribe",
                          systemImage: "waveform.badge.mic")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.accent)
                .disabled(transcriptionService.isTranscribing)
            }

            // Always show audio export even without transcription
            if recording.status != .done {
                Menu {
                    Button(action: { exportAudio(format: .wav) }) {
                        Label("Export as WAV (\(audioSizeEstimate(format: .wav)))", systemImage: "waveform")
                    }
                    Button(action: { exportAudio(format: .mp3) }) {
                        Label("Export as MP3 (\(audioSizeEstimate(format: .mp3)))", systemImage: "waveform.badge.minus")
                    }
                } label: {
                    Label("Export Audio", systemImage: "square.and.arrow.up")
                        .font(.subheadline.weight(.medium))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            // Show in Finder
            Button(action: { store.showInFinder(recording) }) {
                Image(systemName: "folder")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Show in Finder")

            // Delete
            Button(action: { showingDeleteConfirm = true }) {
                Image(systemName: "trash")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Delete Recording")
        }
    }

    // MARK: - State Views

    private var pendingView: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(AppTheme.accent.opacity(0.08))
                    .frame(width: 100, height: 100)
                Image(systemName: recording.status.isResumable ? "arrow.trianglehead.clockwise.rotate.90" : "text.magnifyingglass")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(AppTheme.accent.opacity(0.6))
            }
            Text(recording.status.isResumable ? "Transcription in progress — paused" : "Ready to transcribe")
                .font(.title3.weight(.medium))
                .foregroundStyle(.secondary)
            Text(recording.status.isResumable
                 ? "Partial progress is saved. Resume to continue where it left off."
                 : "Click Transcribe to convert speech to text with speaker detection")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
            Button(action: { Task { await transcribeRecording() } }) {
                HStack(spacing: 6) {
                    Image(systemName: "waveform.badge.mic")
                    Text(recording.status.isResumable ? "Resume Transcription" : "Transcribe Now")
                }
                .font(.body.weight(.semibold))
                .frame(width: 180, height: 40)
                .background(AppTheme.heroGradient)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(transcriptionService.isTranscribing)
        }
    }

    @ViewBuilder
    private var processingView: some View {
        if transcriptionService.isActive(recording.id) {
            activeTranscriptionView
        } else if let position = transcriptionService.queuePosition(of: recording.id) {
            queuedView(position: position)
        } else {
            // Status says processing but no job — stale state (repaired on next launch)
            activeTranscriptionView
        }
    }

    private var activeTranscriptionView: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(AppTheme.processing.opacity(0.08))
                    .frame(width: 100, height: 100)
                ProgressView()
                    .scaleEffect(1.5)
                    .tint(AppTheme.processing)
            }
            Text(transcriptionService.progress.isEmpty ? "Transcribing..." : transcriptionService.progress)
                .font(.title3.weight(.medium))
                .foregroundStyle(.secondary)

            // Progress bar
            VStack(spacing: 8) {
                ProgressView(value: transcriptionService.progressPercent)
                    .progressViewStyle(.linear)
                    .tint(AppTheme.processing)
                    .frame(maxWidth: 300)

                Text("\(Int(transcriptionService.progressPercent * 100))%")
                    .font(.caption.weight(.medium).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            Text(transcriptionService.etaText ?? "Estimating time remaining…")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())

            HStack(spacing: 12) {
                Button(action: { transcriptionService.pause(recording.id) }) {
                    Label("Pause", systemImage: "pause.fill")
                        .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.bordered)
                .help("Pause — progress is saved and you can resume later")

                Button(role: .destructive, action: { transcriptionService.cancel(recording.id) }) {
                    Label("Cancel", systemImage: "xmark")
                        .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.bordered)
                .help("Cancel and discard progress")
            }
        }
    }

    private func queuedView(position: Int) -> some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(AppTheme.processing.opacity(0.08))
                    .frame(width: 100, height: 100)
                Image(systemName: "list.number")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(AppTheme.processing)
            }
            Text("Waiting in queue")
                .font(.title3.weight(.medium))
                .foregroundStyle(.secondary)
            Text("Position \(position) — will start automatically")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
            Button(role: .destructive, action: { transcriptionService.cancel(recording.id) }) {
                Label("Remove from Queue", systemImage: "xmark")
                    .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.bordered)
        }
    }

    private var failedView: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(AppTheme.warning.opacity(0.1))
                    .frame(width: 100, height: 100)
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(AppTheme.warning)
            }
            Text("Transcription failed")
                .font(.title3.weight(.medium))
            Button(action: { Task { await transcribeRecording() } }) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.counterclockwise")
                    Text("Retry")
                }
                .font(.body.weight(.semibold))
                .frame(width: 140, height: 40)
                .background(AppTheme.heroGradient)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    private func interactiveTranscriptContent(_ segs: [TranscriptionSegment]) -> some View {
        VStack(spacing: 0) {
            // Search bar
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.tertiary)
                TextField("Find in transcript...", text: $transcriptSearchQuery)
                    .textFieldStyle(.plain)
                if !transcriptSearchQuery.isEmpty {
                    let count = countMatchesInSegments(segs, query: transcriptSearchQuery)
                    Text("\(count) match\(count == 1 ? "" : "es")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button(action: { transcriptSearchQuery = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(.bar)
            Divider()

            // Speaker rename pills
            if !uniqueSpeakers(in: segs).isEmpty {
                speakerPillsBar(speakers: uniqueSpeakers(in: segs))
                Divider()
            }

            InteractiveTranscriptView(
                segments: segs,
                currentTime: audioRecorder.playbackTime,
                isPlaying: isPlayingThis,
                onSeek: { time in
                    audioRecorder.seekAndPlay(to: time, recording: recording)
                },
                speakerNames: speakerNames,
                searchQuery: transcriptSearchQuery
            )
        }
    }

    private func speakerPillsBar(speakers: [(id: String, num: Int)]) -> some View {
        HStack(spacing: 8) {
            Text("Speakers:")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(speakers, id: \.id) { speaker in
                let displayName = speakerNames[speaker.id] ?? "Speaker \(speaker.num)"
                Button(action: {
                    editingSpeakerID = speaker.id
                    editingSpeakerName = speakerNames[speaker.id] ?? ""
                }) {
                    HStack(spacing: 4) {
                        Text(displayName)
                            .font(.caption.weight(.medium))
                        Image(systemName: "pencil")
                            .font(.system(size: 9))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(AppTheme.accent.opacity(0.1), in: Capsule())
                }
                .buttonStyle(.plain)
                .popover(isPresented: Binding(
                    get: { editingSpeakerID == speaker.id },
                    set: { if !$0 { editingSpeakerID = nil } }
                )) {
                    VStack(spacing: 8) {
                        Text("Rename Speaker \(speaker.num)")
                            .font(.headline)
                        TextField("Name", text: $editingSpeakerName)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 200)
                            .onSubmit {
                                saveSpeakerName(speakerID: speaker.id)
                            }
                        HStack {
                            if speakerNames[speaker.id] != nil {
                                Button("Reset") {
                                    speakerNames.removeValue(forKey: speaker.id)
                                    editingSpeakerID = nil
                                    saveSpeakerNames()
                                }
                                .buttonStyle(.bordered)
                            }
                            Spacer()
                            Button("Cancel") { editingSpeakerID = nil }
                                .buttonStyle(.bordered)
                            Button("Save") {
                                saveSpeakerName(speakerID: speaker.id)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(AppTheme.accent)
                        }
                    }
                    .padding()
                    .frame(width: 260)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private func uniqueSpeakers(in segs: [TranscriptionSegment]) -> [(id: String, num: Int)] {
        var order: [(id: String, num: Int)] = []
        var seen: Set<String> = []
        for seg in segs {
            if !seen.contains(seg.speaker) {
                seen.insert(seg.speaker)
                order.append((id: seg.speaker, num: order.count + 1))
            }
        }
        return order
    }

    private func countMatchesInSegments(_ segs: [TranscriptionSegment], query: String) -> Int {
        guard !query.isEmpty else { return 0 }
        let queryLower = query.lowercased()
        let fullText = segs.map { $0.text }.joined(separator: " ").lowercased()
        var count = 0
        var searchRange = fullText.startIndex..<fullText.endIndex
        while let range = fullText.range(of: queryLower, range: searchRange) {
            count += 1
            searchRange = range.upperBound..<fullText.endIndex
        }
        return count
    }

    private func saveSpeakerName(speakerID: String) {
        let trimmed = editingSpeakerName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            speakerNames.removeValue(forKey: speakerID)
        } else {
            speakerNames[speakerID] = trimmed
        }
        editingSpeakerID = nil
        saveSpeakerNames()
    }

    private func transcriptTabContent(_ content: String) -> some View {
        VStack(spacing: 0) {
            // In-transcript search bar
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.tertiary)
                TextField("Find in transcript...", text: $transcriptSearchQuery)
                    .textFieldStyle(.plain)
                if !transcriptSearchQuery.isEmpty {
                    let matchCount = countMatches(in: content, query: transcriptSearchQuery)
                    Text("\(matchCount) match\(matchCount == 1 ? "" : "es")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button(action: { transcriptSearchQuery = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(.bar)
            Divider()

            ScrollView {
                if transcriptSearchQuery.isEmpty {
                    Text(attributedMarkdown(content))
                        .textSelection(.enabled)
                        .padding(24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(highlightedText(content, query: transcriptSearchQuery))
                        .textSelection(.enabled)
                        .padding(24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // MARK: - Summary Tab

    @ViewBuilder
    private var summaryTabContent: some View {
        if let summary = loadedSummary {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Summary section
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Summary")
                            .font(.title3.weight(.semibold))
                        Text(summary.summary)
                            .textSelection(.enabled)
                    }

                    // Action Items
                    if !summary.actionItems.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Action Items")
                                .font(.title3.weight(.semibold))
                            ForEach(summary.actionItems, id: \.self) { item in
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: "circle")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .padding(.top, 4)
                                    Text(item)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }

                    // Generated name
                    HStack {
                        Text("Suggested name:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(summary.generatedName)
                            .font(.caption.weight(.medium))
                        if recording.name == nil {
                            Button("Use") {
                                store.update(recording.id) { $0.name = summary.generatedName }
                            }
                            .font(.caption)
                            .buttonStyle(.bordered)
                        }
                    }

                    // Regenerate
                    if chatService.isActiveProviderReady {
                        Button(action: { Task { await regenerateSummary() } }) {
                            Label("Regenerate Summary", systemImage: "arrow.counterclockwise")
                                .font(.subheadline)
                        }
                        .buttonStyle(.bordered)
                        .disabled(isRegeneratingSummary)
                    }

                    Text("Generated \(summary.generatedAt.formatted())")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if isRegeneratingSummary {
            VStack(spacing: 12) {
                ProgressView()
                Text("Generating summary...")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } else if chatService.isActiveProviderReady {
            VStack(spacing: 16) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 40))
                    .foregroundStyle(.tertiary)
                Text("No summary yet")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Button(action: { Task { await regenerateSummary() } }) {
                    Label("Generate Summary", systemImage: "sparkles")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.accent)
            }
        } else {
            VStack(spacing: 16) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 40))
                    .foregroundStyle(.tertiary)
                Text("Summarization requires mlx-lm")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text("Install mlx-lm in the transcriber conda environment to generate summaries.")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Toast

    private var copiedToast: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(AppTheme.success)
            Text("Copied to clipboard")
                .font(.subheadline.weight(.medium))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.1), radius: 10, y: 4)
        .padding(.bottom, 16)
    }

    // MARK: - Actions

    private var speakerNamesURL: URL {
        recording.fileURL.deletingPathExtension().appendingPathExtension("speakers.json")
    }

    private func loadMarkdown() {
        guard let url = recording.transcriptionURL else {
            markdownContent = nil
            return
        }
        isLoading = true
        let segmentsURL = recording.fileURL.deletingPathExtension().appendingPathExtension("segments.json")
        DispatchQueue.global(qos: .userInitiated).async {
            let content = try? String(contentsOf: url, encoding: .utf8)
            let segs: [TranscriptionSegment]? = {
                guard let data = try? Data(contentsOf: segmentsURL) else { return nil }
                return try? JSONDecoder().decode([TranscriptionSegment].self, from: data)
            }()
            DispatchQueue.main.async {
                markdownContent = content
                segments = segs
                isLoading = false
            }
        }
        // Also load summary and speaker names sidecars
        loadedSummary = SummarizationService.loadSummary(for: recording)
        loadSpeakerNames()
    }

    private func loadSpeakerNames() {
        guard let data = try? Data(contentsOf: speakerNamesURL),
              let names = try? JSONDecoder().decode([String: String].self, from: data) else {
            speakerNames = [:]
            return
        }
        speakerNames = names
    }

    private func saveSpeakerNames() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        if speakerNames.isEmpty {
            try? FileManager.default.removeItem(at: speakerNamesURL)
        } else if let data = try? encoder.encode(speakerNames) {
            try? data.write(to: speakerNamesURL)
        }
    }

    private func saveName() {
        isEditingName = false
        let trimmed = editName.trimmingCharacters(in: .whitespacesAndNewlines)
        store.update(recording.id) { $0.name = trimmed.isEmpty ? nil : trimmed }
    }

    private func regenerateSummary() async {
        guard let content = markdownContent else { return }
        isRegeneratingSummary = true
        defer { isRegeneratingSummary = false }

        do {
            let summary = try await SummarizationService.summarize(
                transcript: content, provider: chatService.activeProvider)
            SummarizationService.saveSummary(summary, for: recording)
            await MainActor.run { loadedSummary = summary }

            // Auto-set name if not already named
            if recording.name == nil {
                let generatedName = summary.generatedName
                await MainActor.run {
                    store.update(recording.id) { $0.name = generatedName }
                }
            }
        } catch {
            // Silently fail - user can retry
        }
    }

    private func countMatches(in text: String, query: String) -> Int {
        guard !query.isEmpty else { return 0 }
        let lowered = text.lowercased()
        let queryLowered = query.lowercased()
        var count = 0
        var searchRange = lowered.startIndex..<lowered.endIndex
        while let range = lowered.range(of: queryLowered, range: searchRange) {
            count += 1
            searchRange = range.upperBound..<lowered.endIndex
        }
        return count
    }

    private func highlightedText(_ text: String, query: String) -> AttributedString {
        var attributed = AttributedString(text)
        guard !query.isEmpty else { return attributed }
        let loweredText = text.lowercased()
        let loweredQuery = query.lowercased()
        var searchStart = loweredText.startIndex
        while let range = loweredText.range(of: loweredQuery, range: searchStart..<loweredText.endIndex) {
            let attrStart = AttributedString.Index(range.lowerBound, within: attributed)
            let attrEnd = AttributedString.Index(range.upperBound, within: attributed)
            if let attrStart, let attrEnd {
                attributed[attrStart..<attrEnd].backgroundColor = .yellow.opacity(0.4)
                attributed[attrStart..<attrEnd].foregroundColor = .primary
            }
            searchStart = range.upperBound
        }
        return attributed
    }

    private func transcribeRecording() async {
        transcriptionService.enqueue(recording.id)
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Generate transcript markdown with custom speaker names and recording name applied
    private func exportableTranscript() -> String {
        guard let content = markdownContent else { return "" }
        return MarkdownFormatter.applyCustomNames(
            to: content,
            segments: segments,
            customSpeakerNames: speakerNames,
            recordingName: recording.name
        )
    }

    private func exportTranscript() {
        let content = exportableTranscript()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        let baseName = recording.name ?? "transcription_\(recording.date.formatted(.dateTime.year().month().day()))"
        panel.nameFieldStringValue = "\(sanitizeFilename(baseName)).md"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? content.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private enum AudioExportFormat { case wav, mp3 }

    private func audioSizeEstimate(format: AudioExportFormat) -> String {
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: recording.fileURL.path)[.size] as? Int64) ?? 0
        switch format {
        case .wav:
            return formatFileSize(fileSize)
        case .mp3:
            // WAV → MP3 at 128kbps is roughly 1/10th of 16-bit 44.1kHz WAV, or duration-based estimate
            let estimatedMP3 = max(Int64(recording.duration * 16000), fileSize / 10)
            return "~\(formatFileSize(estimatedMP3))"
        }
    }

    private func formatFileSize(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        let kb = Double(bytes) / 1024
        if kb < 1024 { return String(format: "%.0f KB", kb) }
        let mb = kb / 1024
        return String(format: "%.1f MB", mb)
    }

    private func exportAudio(format: AudioExportFormat) {
        let panel = NSSavePanel()
        let baseName = recording.name ?? "recording_\(recording.date.formatted(.dateTime.year().month().day()))"
        let safeName = sanitizeFilename(baseName)

        switch format {
        case .wav:
            panel.allowedContentTypes = [.wav]
            panel.nameFieldStringValue = "\(safeName).wav"
            panel.begin { response in
                guard response == .OK, let url = panel.url else { return }
                try? FileManager.default.copyItem(at: recording.fileURL, to: url)
            }
        case .mp3:
            panel.allowedContentTypes = [.mp3]
            panel.nameFieldStringValue = "\(safeName).mp3"
            panel.begin { response in
                guard response == .OK, let destURL = panel.url else { return }
                self.convertToMP3(source: recording.fileURL, destination: destURL)
            }
        }
    }

    private func convertToMP3(source: URL, destination: URL) {
        Task.detached(priority: .userInitiated) {
            let process = Process()
            // Use ffmpeg (commonly available, also used by whisperX)
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["ffmpeg", "-y", "-i", source.path, "-codec:a", "libmp3lame", "-b:a", "128k", destination.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus != 0 {
                    await MainActor.run {
                        self.audioRecorder.errorMessage = "MP3 conversion failed. Ensure ffmpeg is installed."
                    }
                }
            } catch {
                await MainActor.run {
                    self.audioRecorder.errorMessage = "MP3 conversion failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func exportSummary() {
        guard let summary = loadedSummary else { return }
        var lines: [String] = []
        let title = recording.name ?? "Recording — \(recording.formattedDate)"
        lines.append("# Summary: \(title)")
        lines.append("")
        lines.append("## Summary")
        lines.append("")
        lines.append(summary.summary)
        lines.append("")
        if !summary.actionItems.isEmpty {
            lines.append("## Action Items")
            lines.append("")
            for item in summary.actionItems {
                lines.append("- \(item)")
            }
            lines.append("")
        }
        lines.append("---")
        lines.append("*Generated \(summary.generatedAt.formatted())*")

        let content = lines.joined(separator: "\n")
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        let baseName = recording.name ?? "summary_\(recording.date.formatted(.dateTime.year().month().day()))"
        panel.nameFieldStringValue = "\(sanitizeFilename(baseName))_summary.md"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? content.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private var hasChatHistory: Bool {
        let chatURL = recording.fileURL.deletingPathExtension().appendingPathExtension("chat.json")
        return FileManager.default.fileExists(atPath: chatURL.path)
    }

    private func exportChat() {
        let chatURL = recording.fileURL.deletingPathExtension().appendingPathExtension("chat.json")
        guard let data = try? Data(contentsOf: chatURL),
              let history = try? JSONDecoder().decode(ChatHistory.self, from: data) else { return }

        var lines: [String] = []
        let title = recording.name ?? "Recording — \(recording.formattedDate)"
        lines.append("# Chat: \(title)")
        lines.append("")

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .short
        dateFormatter.timeStyle = .short

        for msg in history.messages where msg.role != .system {
            let sender = msg.role == .user ? "**You**" : "**AI**"
            lines.append("\(sender) — \(dateFormatter.string(from: msg.timestamp))")
            lines.append("")
            lines.append(msg.content)
            lines.append("")
        }

        let content = lines.joined(separator: "\n")
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        let baseName = recording.name ?? "chat_\(recording.date.formatted(.dateTime.year().month().day()))"
        panel.nameFieldStringValue = "\(sanitizeFilename(baseName))_chat.md"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? content.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func sanitizeFilename(_ name: String) -> String {
        let invalidChars = CharacterSet(charactersIn: "/\\:*?\"<>|")
        return name.components(separatedBy: invalidChars).joined(separator: "_")
    }

    private func attributedMarkdown(_ markdown: String) -> AttributedString {
        (try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(markdown)
    }
}
