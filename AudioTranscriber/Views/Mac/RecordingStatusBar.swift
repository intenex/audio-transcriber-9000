import SwiftUI

/// Persistent recording indicator shown across the bottom of every detail
/// page while a recording is live (or being saved), so navigating away from
/// the record screen never hides the fact that capture is running.
struct RecordingStatusBar: View {
    @Environment(AudioRecorder.self) private var audioRecorder
    let onOpenRecordingScreen: () -> Void

    @State private var pulsing = false

    var body: some View {
        HStack(spacing: 10) {
            if audioRecorder.isRecording {
                Circle()
                    .fill(AppTheme.recording)
                    .frame(width: 10, height: 10)
                    .opacity(pulsing ? 0.35 : 1)
                    .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulsing)
                    .onAppear { pulsing = true }

                Text("Recording")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.recording)
                Text(RecordingControlRow.timerText(audioRecorder.recordingDuration))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                if !audioRecorder.inputDescription.isEmpty {
                    Text("· \(audioRecorder.inputDescription)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 12)

                Button("Open", action: onOpenRecordingScreen)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button(role: .destructive) {
                    audioRecorder.stopRecording()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.recording)
                .controlSize(.small)
            } else if audioRecorder.isFinalizingRecording {
                ProgressView()
                    .controlSize(.small)
                Text("Saving recording…")
                    .font(.subheadline.weight(.medium))
                Spacer(minLength: 12)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}
