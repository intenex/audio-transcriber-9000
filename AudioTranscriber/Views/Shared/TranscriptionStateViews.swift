import SwiftUI

// The status/pending/active/queued/failed presentation for a recording,
// shared verbatim by the Mac detail pane and the iOS detail screen.

enum DetailTab: String, CaseIterable {
    case transcript = "Transcript"
    case summary = "Summary"
    case chat = "Chat"
}

struct StatusPill: View {
    let status: TranscriptionStatus
    /// Supplied wherever the queue is reachable, so a processing pill can say
    /// how far along the job actually is instead of just "Processing".
    var recordingID: UUID? = nil
    @Environment(TranscriptionService.self) private var transcriptionService

    var body: some View {
        switch status {
        case .done:
            pill("Transcribed", tint: AppTheme.success)
        case .processing:
            pill(processingLabel, tint: AppTheme.processing)
        case .failed:
            pill("Failed", tint: AppTheme.recording)
        case .paused:
            pill("Paused", tint: AppTheme.warning)
        case .partial:
            pill("Partially transcribed", tint: AppTheme.warning)
        case .pending:
            EmptyView()
        }
    }

    private var processingLabel: String {
        guard let recordingID else { return "Processing…" }
        if transcriptionService.isActive(recordingID) {
            let percent = Int(transcriptionService.progressPercent * 100)
            return percent > 0 ? "Transcribing \(percent)%" : "Transcribing…"
        }
        if let position = transcriptionService.queuePosition(of: recordingID) {
            return "Queued · #\(position)"
        }
        return "Processing…"
    }

    private func pill(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(tint.opacity(0.12), in: Capsule())
    }
}

enum TranscribeEngineHelper {
    static func isConfigured(_ kind: TranscriptionEngineKind) -> Bool {
        switch kind {
        case .local: return true
        case .openAI: return KeychainStore.shared.has(.openAI)
        case .assemblyAI: return KeychainStore.shared.has(.assemblyAI)
        }
    }
}

/// The engine list for a Transcribe menu (with cloud cost estimates and a
/// hint when cloud engines are unkeyed).
struct TranscribeEngineMenuItems: View {
    let recording: Recording
    let onSelect: (TranscriptionEngineKind) -> Void

    var body: some View {
        ForEach(TranscriptionEngineKind.allCases) { kind in
            Button {
                onSelect(kind)
            } label: {
                if kind.isCloud, let cost = TranscriptionCostEstimator.estimateString(duration: recording.duration, kind: kind) {
                    Text("\(kind.displayName)  (\(cost))")
                } else {
                    Text(kind.displayName)
                }
            }
            .disabled(!TranscribeEngineHelper.isConfigured(kind))
        }
        if TranscriptionEngineKind.allCases.contains(where: { $0.isCloud && !TranscribeEngineHelper.isConfigured($0) }) {
            Divider()
            Text("Add API keys in Settings → Transcription to enable cloud engines")
        }
    }
}

struct PendingTranscriptionView: View {
    let recording: Recording
    let defaultEngine: TranscriptionEngineKind
    let onStart: (TranscriptionEngineKind) -> Void

    /// Held between the press and the queue picking the job up, so the button
    /// reads as "working on it" from the first frame. The transition is
    /// normally instant; the timeout only matters when a start is refused
    /// (unconfigured engine, audio still downloading from iCloud).
    @State private var isStarting = false
    @State private var startResetTask: Task<Void, Never>? = nil

    private func start(_ kind: TranscriptionEngineKind) {
        guard !isStarting else { return }
        isStarting = true
        onStart(kind)
        startResetTask?.cancel()
        startResetTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            isStarting = false
        }
    }

    var body: some View {
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
            Menu {
                TranscribeEngineMenuItems(recording: recording, onSelect: start)
            } label: {
                HStack(spacing: 6) {
                    if isStarting {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                        Text("Starting…")
                    } else {
                        Image(systemName: "waveform.badge.mic")
                        Text(recording.status.isResumable ? "Resume Transcription" : "Transcribe Now")
                    }
                }
                .font(.body.weight(.semibold))
                .frame(width: 200, height: 40)
                .background(isStarting ? AnyShapeStyle(Color.secondary.opacity(0.35)) : AnyShapeStyle(AppTheme.heroGradient))
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } primaryAction: {
                start(defaultEngine)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .fixedSize()
            .disabled(isStarting)

            Text(isStarting
                 ? "Preparing \(defaultEngine.displayName)…"
                 : "Using \(defaultEngine.displayName) — hold for other engines")
                .font(.caption)
                .foregroundStyle(.quaternary)
        }
        .onDisappear { startResetTask?.cancel() }
        .onChange(of: recording.id) { _, _ in
            startResetTask?.cancel()
            isStarting = false
        }
    }
}

struct ActiveTranscriptionView: View {
    let recordingID: UUID
    @Environment(TranscriptionService.self) private var transcriptionService

    var body: some View {
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

            VStack(spacing: 8) {
                // Model loading and audio decoding happen before there is any
                // fraction to report; a stuck 0% bar reads as "nothing is
                // happening", which is exactly the wrong impression.
                if transcriptionService.progressPercent > 0 {
                    ProgressView(value: min(1, transcriptionService.progressPercent))
                        .progressViewStyle(.linear)
                        .tint(AppTheme.processing)
                        .frame(maxWidth: 300)

                    Text("\(Int(transcriptionService.progressPercent * 100))% complete")
                        .font(.caption.weight(.medium).monospacedDigit())
                        .foregroundStyle(.tertiary)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(AppTheme.processing)
                        .frame(maxWidth: 300)

                    Text("Getting started…")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.tertiary)
                }
            }

            Text(transcriptionService.etaText ?? "Estimating time remaining…")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())

            HStack(spacing: 12) {
                Button(action: { transcriptionService.pause(recordingID) }) {
                    Label("Pause", systemImage: "pause.fill")
                        .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.bordered)
                .help("Pause — progress is saved and you can resume later")

                Button(role: .destructive, action: { transcriptionService.cancel(recordingID) }) {
                    Label("Cancel", systemImage: "xmark")
                        .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.bordered)
                .help("Cancel and discard progress")
            }
        }
    }
}

struct QueuedTranscriptionView: View {
    let recordingID: UUID
    let position: Int
    @Environment(TranscriptionService.self) private var transcriptionService

    var body: some View {
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
            Button(role: .destructive, action: { transcriptionService.cancel(recordingID) }) {
                Label("Remove from Queue", systemImage: "xmark")
                    .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.bordered)
        }
    }
}

struct FailedTranscriptionView: View {
    var lastError: String? = nil
    let onRetry: () -> Void

    var body: some View {
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
            if let lastError, !lastError.isEmpty {
                Text(lastError)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                    .textSelection(.enabled)
            }
            Button(action: onRetry) {
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
}
