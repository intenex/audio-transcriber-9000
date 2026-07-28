#if os(iOS)
import SwiftUI

/// iPhone detail screen: header + playback bar + Transcript|Summary|Chat
/// tabs, composed almost entirely from the shared pieces the Mac uses.
struct RecordingDetailView: View {
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
    @State private var selectedTab: DetailTab = .transcript
    @State private var loadedSummary: RecordingSummary? = nil
    @State private var isRegeneratingSummary = false
    @State private var summaryError: String? = nil
    @State private var transcriptSearchQuery = ""
    @State private var speakerNames: [String: String] = [:]
    @State private var editingSpeakerID: String? = nil
    @State private var editingSpeakerName: String = ""
    @State private var rememberVoice = true
    @State private var isEnrollingVoice = false
    @State private var isEditingName = false
    @State private var editName = ""
    @State private var cloudConfirmKind: TranscriptionEngineKind? = nil
    @State private var shareItem: ShareItem? = nil
    @AppStorage("defaultTranscriptionEngine") private var defaultEngineRaw = TranscriptionEngineKind.local.rawValue
    @AppStorage("confirmCloudTranscription") private var confirmCloud = true

    private var isPlayingThis: Bool {
        audioRecorder.isPlaying && audioRecorder.playingRecordingID == recording.id
    }

    private var defaultEngineKind: TranscriptionEngineKind {
        TranscriptionEngineKind(rawValue: defaultEngineRaw) ?? .local
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if isPlayingThis {
                playbackBar
            }
            if recording.status == .done {
                Picker("View", selection: $selectedTab) {
                    ForEach(DetailTab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                shareMenu
            }
        }
        .onAppear { loadSidecars() }
        .onChange(of: recording.id) { _, _ in
            transcriptSearchQuery = ""
            editingSpeakerID = nil
            loadSidecars()
        }
        .onChange(of: recording.status) { _, _ in loadSidecars() }
        .sheet(item: $cloudConfirmKind) { kind in
            CloudTranscribeConfirmSheet(recording: recording, engineKind: kind) {
                transcriptionService.enqueue(recording.id, using: kind)
            }
        }
        .sheet(item: $shareItem) { item in
            ActivityShareSheet(items: [item.url])
        }
        .alert("Rename Recording", isPresented: $isEditingName) {
            TextField("Name", text: $editName)
            Button("Save") {
                let trimmed = editName.trimmingCharacters(in: .whitespacesAndNewlines)
                store.update(recording.id) { $0.name = trimmed.isEmpty ? nil : trimmed }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Button(action: { audioRecorder.playRecording(recording) }) {
                ZStack {
                    Circle()
                        .fill(isPlayingThis ? AppTheme.accent : AppTheme.accent.opacity(0.1))
                        .frame(width: 40, height: 40)
                    Image(systemName: isPlayingThis ? "stop.fill" : "play.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(isPlayingThis ? .white : AppTheme.accent)
                }
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(recording.displayName)
                    .font(.headline)
                    .lineLimit(1)
                    .onTapGesture {
                        editName = recording.name ?? ""
                        isEditingName = true
                    }
                HStack(spacing: 6) {
                    Label(recording.durationString, systemImage: "clock")
                        .labelStyle(.titleOnly)
                    Text(recording.formatAndSizeLabel)
                    StatusPill(status: recording.status, recordingID: recording.id)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let engine = recording.engineUsed {
                    Label(engine, systemImage: "cpu")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var playbackBar: some View {
        HStack(spacing: 10) {
            Text(timeString(audioRecorder.playbackTime))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Slider(
                value: Binding(
                    get: { min(audioRecorder.playbackTime, recording.duration) },
                    set: { audioRecorder.seek(to: $0) }
                ),
                in: 0...max(1, recording.duration)
            )
            Text(timeString(recording.duration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
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
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch recording.status {
        case .pending, .paused, .partial:
            PendingTranscriptionView(recording: recording,
                                     defaultEngine: defaultEngineKind,
                                     onStart: startTranscription)
        case .processing:
            if transcriptionService.isActive(recording.id) {
                ActiveTranscriptionView(recordingID: recording.id)
            } else if let position = transcriptionService.queuePosition(of: recording.id) {
                QueuedTranscriptionView(recordingID: recording.id, position: position)
            } else {
                ActiveTranscriptionView(recordingID: recording.id)
            }
        case .done:
            switch selectedTab {
            case .transcript:
                transcriptTab
            case .summary:
                SummaryTabView(recording: recording,
                               markdownContent: markdownContent,
                               loadedSummary: $loadedSummary,
                               isRegenerating: $isRegeneratingSummary,
                               summaryError: $summaryError)
            case .chat:
                ChatSessionView(context: .recording(recording))
            }
        case .failed:
            FailedTranscriptionView(lastError: recording.lastError,
                                    onRetry: { startTranscription(using: defaultEngineKind) })
        }
    }

    @ViewBuilder
    private var transcriptTab: some View {
        if let segs = segments, !segs.isEmpty {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.tertiary)
                    TextField("Find in transcript...", text: $transcriptSearchQuery)
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()
                    if !transcriptSearchQuery.isEmpty {
                        Button(action: { transcriptSearchQuery = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                Divider()

                let speakers = SpeakerPillsBar.uniqueSpeakers(in: segs)
                if !speakers.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
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
                    }
                    Divider()
                }

                InteractiveTranscriptViewIOS(
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
        } else if let content = markdownContent {
            ScrollView {
                Text(attributedMarkdown(content))
                    .textSelection(.enabled)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ProgressView("Loading transcript...")
        }
    }

    // MARK: - Share

    private struct ShareItem: Identifiable {
        let id = UUID()
        let url: URL
    }

    @ViewBuilder
    private var shareMenu: some View {
        Menu {
            if recording.status == .done, markdownContent != nil {
                Button {
                    UIPasteboard.general.string = exportableTranscript()
                } label: {
                    Label("Copy Transcript", systemImage: "doc.on.doc")
                }
                Button {
                    shareMarkdown(exportableTranscript(), suffix: "")
                } label: {
                    Label("Share Transcript (.md)", systemImage: "doc.text")
                }
            }
            if let summary = loadedSummary {
                Button {
                    shareMarkdown(TranscriptExportContent.summaryMarkdown(summary, recording: recording), suffix: "_summary")
                } label: {
                    Label("Share Summary (.md)", systemImage: "doc.text.magnifyingglass")
                }
            }
            if let chat = TranscriptExportContent.chatMarkdown(for: recording) {
                Button {
                    shareMarkdown(chat, suffix: "_chat")
                } label: {
                    Label("Share Chat (.md)", systemImage: "bubble.left.and.bubble.right")
                }
            }
            Button {
                shareItem = ShareItem(url: recording.fileURL)
            } label: {
                Label("Share Audio (\(recording.formatAndSizeLabel))", systemImage: "waveform")
            }
        } label: {
            Image(systemName: "square.and.arrow.up")
        }
    }

    private func shareMarkdown(_ content: String, suffix: String) {
        let baseName = recording.name ?? "recording_\(recording.date.formatted(.dateTime.year().month().day()))"
        let filename = "\(TranscriptExportContent.sanitizeFilename(baseName))\(suffix).md"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try? content.write(to: url, atomically: true, encoding: .utf8)
        shareItem = ShareItem(url: url)
    }

    private func exportableTranscript() -> String {
        guard let content = markdownContent else { return "" }
        return MarkdownFormatter.applyCustomNames(
            to: content,
            segments: segments,
            customSpeakerNames: speakerNames,
            recordingName: recording.name
        )
    }

    // MARK: - Actions (mirrors the Mac view)

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

    private var speakerNamesURL: URL { recording.speakersURL }

    private func loadSidecars() {
        guard let url = recording.transcriptionURL else {
            markdownContent = nil
            segments = nil
            loadedSummary = SummarizationService.loadSummary(for: recording)
            return
        }
        let segmentsURL = recording.segmentsURL
        DispatchQueue.global(qos: .userInitiated).async {
            let content = try? String(contentsOf: url, encoding: .utf8)
            let segs: [TranscriptionSegment]? = {
                guard let data = try? Data(contentsOf: segmentsURL) else { return nil }
                return try? JSONDecoder().decode([TranscriptionSegment].self, from: data)
            }()
            DispatchQueue.main.async {
                markdownContent = content
                segments = segs
            }
        }
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

    private func saveSpeakerName(speakerID: String) {
        let trimmed = editingSpeakerName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            speakerNames.removeValue(forKey: speakerID)
        } else {
            speakerNames[speakerID] = trimmed
            if rememberVoice, let segs = segments, !segs.isEmpty, modelManager.allReady {
                isEnrollingVoice = true
                Task {
                    defer { isEnrollingVoice = false }
                    await VoiceEnrollmentAction.enroll(
                        name: trimmed, speakerID: speakerID, segments: segs,
                        audioURL: recording.fileURL, recordingID: recording.id,
                        engine: transcriptionService.localFluidEngine,
                        library: speakerLibrary)
                }
            }
        }
        editingSpeakerID = nil
        saveSpeakerNames()
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
}

/// UIActivityViewController wrapper for file sharing.
struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif
