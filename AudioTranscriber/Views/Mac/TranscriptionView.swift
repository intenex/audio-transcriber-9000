import SwiftUI
import AppKit
import CoreMedia
import UniformTypeIdentifiers

struct TranscriptionView: View {
    let recording: Recording
    @Environment(RecordingStore.self) private var store
    @Environment(TranscriptionService.self) private var transcriptionService
    @Environment(AudioRecorder.self) private var audioRecorder
    @Environment(ChatService.self) private var chatService
    @Environment(SpeakerLibraryStore.self) private var speakerLibrary
    @Environment(ModelManager.self) private var modelManager
    @Environment(CloudSyncManager.self) private var cloudSync

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
    @State private var summaryError: String? = nil
    @State private var transcriptSearchQuery = ""
    @State private var speakerNames: [String: String] = [:]
    @State private var editingSpeakerID: String? = nil
    @State private var editingSpeakerName: String = ""
    @State private var cloudConfirmKind: TranscriptionEngineKind? = nil
    @State private var rememberVoice = true
    @State private var isEnrollingVoice = false
    @AppStorage("defaultTranscriptionEngine") private var defaultEngineRaw = TranscriptionEngineKind.local.rawValue
    @AppStorage("confirmCloudTranscription") private var confirmCloud = true

    private var isPlayingThis: Bool {
        audioRecorder.isPlaying && audioRecorder.playingRecordingID == recording.id
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            if isPlayingThis {
                playbackBar
            }
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
        .onChange(of: recording.id) { _, _ in
            // Detail view identity persists across sidebar selection changes —
            // reset per-recording state or the previous recording's leaks through.
            transcriptSearchQuery = ""
            editingSpeakerID = nil
            isEditingName = false
            loadMarkdown()
        }
        .onChange(of: recording.status) { _, _ in loadMarkdown() }
        .onChange(of: recording.transcriptionURL) { _, _ in loadMarkdown() }
        .sheet(item: $cloudConfirmKind) { kind in
            CloudTranscribeConfirmSheet(recording: recording, engineKind: kind) {
                transcriptionService.enqueue(recording.id, using: kind)
            }
        }
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
                    Text(recording.formatAndSizeLabel)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    statusPill
                    if let engine = recording.engineUsed {
                        Label(engine, systemImage: "cpu")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .help("Transcribed with \(engine)")
                    }
                }
            }

            Spacer()
            actionButtons
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: - Playback bar

    private var playbackBar: some View {
        HStack(spacing: 10) {
            Text(timeString(audioRecorder.playbackTime))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)

            Slider(
                value: Binding(
                    get: { min(audioRecorder.playbackTime, recording.duration) },
                    set: { audioRecorder.seek(to: $0) }
                ),
                in: 0...max(1, recording.duration)
            )
            .controlSize(.small)

            Text(timeString(recording.duration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 52, alignment: .leading)

            Menu {
                ForEach([0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
                    Button {
                        audioRecorder.setPlaybackRate(Float(rate))
                    } label: {
                        if abs(Double(audioRecorder.playbackRate) - rate) < 0.01 {
                            Label(rateLabel(rate), systemImage: "checkmark")
                        } else {
                            Text(rateLabel(rate))
                        }
                    }
                }
            } label: {
                Text(rateLabel(Double(audioRecorder.playbackRate)))
                    .font(.caption.weight(.semibold).monospacedDigit())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Playback speed")
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .background(.bar)
    }

    private func timeString(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    private func rateLabel(_ rate: Double) -> String {
        rate == rate.rounded() ? "\(Int(rate))×" : String(format: "%.2g×", rate)
    }

    private var statusPill: some View {
        StatusPill(status: recording.status)
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
                        Button(action: { exportAudio(format: .original) }) {
                            Label("Export Original \(originalAudioExtension) (\(audioSizeEstimate(format: .original)))", systemImage: "waveform")
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
                transcribeMenu(compact: true)
            }

            // Always show audio export even without transcription
            if recording.status != .done {
                Menu {
                    Button(action: { exportAudio(format: .original) }) {
                        Label("Export Original \(originalAudioExtension) (\(audioSizeEstimate(format: .original)))", systemImage: "waveform")
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
        PendingTranscriptionView(recording: recording,
                                 defaultEngine: defaultEngineKind,
                                 onStart: startTranscription)
    }

    // MARK: - Engine selection

    private var defaultEngineKind: TranscriptionEngineKind {
        TranscriptionEngineKind(rawValue: defaultEngineRaw) ?? .local
    }

    private func transcribeMenu(compact: Bool) -> some View {
        Menu {
            TranscribeEngineMenuItems(recording: recording, onSelect: startTranscription)
        } label: {
            Label(recording.status.isResumable ? "Resume" : "Transcribe",
                  systemImage: "waveform.badge.mic")
                .font(.subheadline.weight(.semibold))
        } primaryAction: {
            startTranscription(using: defaultEngineKind)
        }
        .menuStyle(.button)
        .fixedSize()
    }

    private func startTranscription(using kind: TranscriptionEngineKind) {
        guard TranscribeEngineHelper.isConfigured(kind) else { return }
        if case .placeholder = cloudSync.state(for: recording) {
            cloudSync.requestDownload(recording)
            store.infoMessage = "Downloading “\(recording.displayName)” from iCloud first — start the transcription again once it's downloaded."
            return
        }
        if kind.isCloud && confirmCloud {
            cloudConfirmKind = kind
        } else {
            transcriptionService.enqueue(recording.id, using: kind)
        }
    }

    @ViewBuilder
    private var processingView: some View {
        if transcriptionService.isActive(recording.id) {
            ActiveTranscriptionView(recordingID: recording.id)
        } else if let position = transcriptionService.queuePosition(of: recording.id) {
            QueuedTranscriptionView(recordingID: recording.id, position: position)
        } else {
            // Status says processing but no job — stale state (repaired on next launch)
            ActiveTranscriptionView(recordingID: recording.id)
        }
    }

    private var failedView: some View {
        FailedTranscriptionView(onRetry: { startTranscription(using: defaultEngineKind) })
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
            let speakers = SpeakerPillsBar.uniqueSpeakers(in: segs)
            if !speakers.isEmpty {
                SpeakerPillsBar(speakers: speakers,
                                speakerNames: $speakerNames,
                                editingSpeakerID: $editingSpeakerID,
                                editingSpeakerName: $editingSpeakerName,
                                rememberVoice: $rememberVoice,
                                isEnrolling: isEnrollingVoice,
                                onSave: { saveSpeakerName(speakerID: $0) },
                                onReset: { speakerID in
                                    speakerNames.removeValue(forKey: speakerID)
                                    editingSpeakerID = nil
                                    saveSpeakerNames()
                                })
                Divider()
            }

            InteractiveTranscriptView(
                contentID: recording.id.uuidString,
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
            if rememberVoice {
                enrollVoice(name: trimmed, speakerID: speakerID)
            }
        }
        editingSpeakerID = nil
        saveSpeakerNames()
    }

    /// Extract reference clips + embedding for the named speaker and store them
    /// in the voice library so they're auto-recognized in future transcripts.
    private func enrollVoice(name: String, speakerID: String) {
        guard let segs = segments, !segs.isEmpty else { return }
        // Embedding extraction needs the local speaker models; skip quietly if absent.
        guard modelManager.allReady else { return }

        isEnrollingVoice = true
        Task {
            defer { isEnrollingVoice = false }
            await VoiceEnrollmentAction.enroll(
                name: name, speakerID: speakerID, segments: segs,
                audioURL: recording.fileURL, recordingID: recording.id,
                engine: transcriptionService.localFluidEngine,
                library: speakerLibrary)
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

    private var summaryTabContent: some View {
        SummaryTabView(recording: recording,
                       markdownContent: markdownContent,
                       loadedSummary: $loadedSummary,
                       isRegenerating: $isRegeneratingSummary,
                       summaryError: $summaryError)
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
            try? AtomicFile.write(data, to: speakerNamesURL)
        }
    }

    private func saveName() {
        isEditingName = false
        let trimmed = editName.trimmingCharacters(in: .whitespacesAndNewlines)
        store.update(recording.id) { $0.name = trimmed.isEmpty ? nil : trimmed }
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

    private enum AudioExportFormat { case original, mp3 }

    /// The recording's on-disk container ("WAV", "M4A", …).
    private var originalAudioExtension: String {
        recording.fileURL.pathExtension.uppercased()
    }

    private func audioSizeEstimate(format: AudioExportFormat) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: recording.fileURL.path)
        let fileSize = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        switch format {
        case .original:
            return formatFileSize(fileSize)
        case .mp3:
            // MP3 at 128 kbps ≈ 16 KB/s of audio; never larger than the source.
            let estimatedMP3 = min(fileSize, Int64(recording.duration * 16_000))
            return "~\(formatFileSize(max(estimatedMP3, 1024)))"
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
        case .original:
            let ext = recording.fileURL.pathExtension.lowercased()
            if let type = UTType(filenameExtension: ext) {
                panel.allowedContentTypes = [type]
            }
            panel.nameFieldStringValue = "\(safeName).\(ext)"
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
        let content = TranscriptExportContent.summaryMarkdown(summary, recording: recording)
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
        guard let content = TranscriptExportContent.chatMarkdown(for: recording) else { return }
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
        TranscriptExportContent.sanitizeFilename(name)
    }
}
