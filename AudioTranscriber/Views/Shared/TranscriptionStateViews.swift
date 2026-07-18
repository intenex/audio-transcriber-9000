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

    var body: some View {
        switch status {
        case .done:
            pill("Transcribed", tint: AppTheme.success)
        case .processing:
            pill("Processing...", tint: AppTheme.processing)
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
                TranscribeEngineMenuItems(recording: recording, onSelect: onStart)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "waveform.badge.mic")
                    Text(recording.status.isResumable ? "Resume Transcription" : "Transcribe Now")
                }
                .font(.body.weight(.semibold))
                .frame(width: 200, height: 40)
                .background(AppTheme.heroGradient)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } primaryAction: {
                onStart(defaultEngine)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .fixedSize()

            Text("Using \(defaultEngine.displayName) — hold for other engines")
                .font(.caption)
                .foregroundStyle(.quaternary)
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
