import SwiftUI

/// Pre-flight confirmation for cloud transcription: duration, upload size
/// after compression, part count, and estimated cost.
struct CloudTranscribeConfirmSheet: View {
    let recording: Recording
    let engineKind: TranscriptionEngineKind
    let onConfirm: () -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage("confirmCloudTranscription") private var confirmCloud = true

    private var estimatedUploadBytes: Int {
        CloudAudioSpec.estimatedBytes(forSeconds: recording.duration)
    }

    private var partCount: Int {
        engineKind == .openAI
            ? AudioSplitPlanner.plan(durationSeconds: recording.duration).count
            : 1
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "icloud.and.arrow.up")
                .font(.system(size: 32))
                .foregroundStyle(AppTheme.accent)

            Text("Transcribe with \(engineKind.displayName)?")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Duration", value: recording.durationString)
                LabeledContent("Upload size", value: "~\(ByteCountFormatter.string(fromByteCount: Int64(estimatedUploadBytes), countStyle: .file)) (compressed)")
                if partCount > 1 {
                    LabeledContent("Parts", value: "\(partCount) (25 MB limit per request)")
                }
                if let cost = TranscriptionCostEstimator.estimateString(duration: recording.duration, kind: engineKind) {
                    LabeledContent("Estimated cost", value: cost)
                }
            }
            .font(.subheadline)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))

            Text("Audio is compressed to 16 kHz mono AAC before upload. Estimate based on provider list pricing.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

            Toggle("Don't ask again", isOn: Binding(
                get: { !confirmCloud },
                set: { confirmCloud = !$0 }
            ))
            .font(.caption)

            HStack(spacing: 12) {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Transcribe") {
                    dismiss()
                    onConfirm()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.accent)
            }
        }
        .padding(24)
        .frame(width: 380)
    }
}
