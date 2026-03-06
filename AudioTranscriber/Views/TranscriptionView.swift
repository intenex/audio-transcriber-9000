import SwiftUI
import AppKit

enum DetailTab: String, CaseIterable {
    case transcript = "Transcript"
    case summary = "Summary"
    case chat = "Chat"
}

struct TranscriptionView: View {
    let recording: Recording
    @Environment(TranscriptionService.self) private var transcriptionService
    @Environment(AudioRecorder.self) private var audioRecorder
    @Environment(LLMService.self) private var llmService

    @State private var markdownContent: String? = nil
    @State private var isLoading = false
    @State private var showingDeleteConfirm = false
    @State private var showCopiedToast = false
    @State private var selectedTab: DetailTab = .transcript
    @State private var isEditingName = false
    @State private var editName = ""
    @State private var loadedSummary: RecordingSummary? = nil
    @State private var isRegeneratingSummary = false
    @State private var transcriptSearchQuery = ""

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
                case .pending:
                    pendingView
                case .processing:
                    processingView
                case .done:
                    switch selectedTab {
                    case .transcript:
                        if let content = markdownContent {
                            transcriptTabContent(content)
                        } else {
                            ProgressView("Loading transcript...")
                        }
                    case .summary:
                        summaryTabContent
                    case .chat:
                        ChatView(recording: recording)
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
                audioRecorder.deleteRecording(recording)
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
        case .pending:
            EmptyView()
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        HStack(spacing: 8) {
            if recording.status == .done, markdownContent != nil {
                Button(action: {
                    copyToClipboard(markdownContent!)
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

                Button(action: { exportMarkdown(markdownContent!) }) {
                    Label("Export", systemImage: "square.and.arrow.up")
                        .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.bordered)
            }

            if recording.status == .pending || recording.status == .failed {
                Button(action: { Task { await transcribeRecording() } }) {
                    Label("Transcribe", systemImage: "waveform.badge.mic")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.accent)
                .disabled(transcriptionService.isTranscribing)
            }

            // Show in Finder
            Button(action: { audioRecorder.showInFinder(recording) }) {
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
                Image(systemName: "text.magnifyingglass")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(AppTheme.accent.opacity(0.6))
            }
            Text("Ready to transcribe")
                .font(.title3.weight(.medium))
                .foregroundStyle(.secondary)
            Text("Click Transcribe to convert speech to text with speaker detection")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
            Button(action: { Task { await transcribeRecording() } }) {
                HStack(spacing: 6) {
                    Image(systemName: "waveform.badge.mic")
                    Text("Transcribe Now")
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

    private var processingView: some View {
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

            Text("This may take a few minutes for longer recordings")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
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
                                if let idx = audioRecorder.recordings.firstIndex(where: { $0.id == recording.id }) {
                                    audioRecorder.recordings[idx].name = summary.generatedName
                                    audioRecorder.saveRecordings()
                                }
                            }
                            .font(.caption)
                            .buttonStyle(.bordered)
                        }
                    }

                    // Regenerate
                    if llmService.isAvailable {
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
        } else if llmService.isAvailable {
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

    private func loadMarkdown() {
        guard let url = recording.transcriptionURL else {
            markdownContent = nil
            return
        }
        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let content = try? String(contentsOf: url, encoding: .utf8)
            DispatchQueue.main.async {
                markdownContent = content
                isLoading = false
            }
        }
        // Also load summary sidecar
        loadedSummary = SummarizationService.loadSummary(for: recording)
    }

    private func saveName() {
        isEditingName = false
        let trimmed = editName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let idx = audioRecorder.recordings.firstIndex(where: { $0.id == recording.id }) {
            audioRecorder.recordings[idx].name = trimmed.isEmpty ? nil : trimmed
            audioRecorder.saveRecordings()
        }
    }

    private func regenerateSummary() async {
        guard let content = markdownContent else { return }
        isRegeneratingSummary = true
        defer { isRegeneratingSummary = false }

        do {
            let summary = try await SummarizationService.summarize(transcript: content, llm: llmService)
            SummarizationService.saveSummary(summary, for: recording)
            await MainActor.run { loadedSummary = summary }

            // Auto-set name if not already named
            if recording.name == nil {
                if let idx = audioRecorder.recordings.firstIndex(where: { $0.id == recording.id }) {
                    await MainActor.run {
                        audioRecorder.recordings[idx].name = summary.generatedName
                        audioRecorder.saveRecordings()
                    }
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
        guard let idx = audioRecorder.recordings.firstIndex(where: { $0.id == recording.id }) else { return }
        // Update status in the observable array immediately so processingView shows
        // and both transcribe buttons become inaccessible before the async work starts.
        audioRecorder.recordings[idx].status = .processing
        var mutable = audioRecorder.recordings[idx]
        await transcriptionService.transcribe(recording: &mutable)
        if let updatedIdx = audioRecorder.recordings.firstIndex(where: { $0.id == mutable.id }) {
            audioRecorder.recordings[updatedIdx] = mutable
            audioRecorder.saveRecordings()
        }
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func exportMarkdown(_ content: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        let dateStr = recording.date.formatted(.dateTime.year().month().day())
        panel.nameFieldStringValue = "transcription_\(dateStr).md"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? content.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func attributedMarkdown(_ markdown: String) -> AttributedString {
        (try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(markdown)
    }
}
