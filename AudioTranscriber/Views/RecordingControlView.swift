import SwiftUI

struct RecordingControlView: View {
    @Environment(AudioRecorder.self) private var audioRecorder

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 32) {
                // Hero icon with animated ring
                ZStack {
                    // Outer pulsing ring when recording
                    if audioRecorder.isRecording {
                        Circle()
                            .stroke(AppTheme.recording.opacity(0.3), lineWidth: 3)
                            .frame(width: 140, height: 140)
                            .scaleEffect(audioRecorder.isRecording ? 1.2 : 1.0)
                            .opacity(audioRecorder.isRecording ? 0 : 1)
                            .animation(.easeInOut(duration: 1.5).repeatForever(autoreverses: false), value: audioRecorder.isRecording)
                    }

                    // Background circle
                    Circle()
                        .fill(audioRecorder.isRecording ? AppTheme.recordingGradient : AppTheme.heroGradient)
                        .frame(width: 110, height: 110)
                        .shadow(color: (audioRecorder.isRecording ? AppTheme.recording : AppTheme.accent).opacity(0.4), radius: 20, y: 8)

                    // Icon
                    Image(systemName: audioRecorder.isRecording ? "waveform" : "mic.fill")
                        .font(.system(size: 40, weight: .medium))
                        .foregroundStyle(.white)
                        .symbolEffect(.variableColor.iterative, isActive: audioRecorder.isRecording)
                }

                // Timer
                Text(timerString)
                    .font(.system(size: 56, weight: .ultraLight, design: .rounded))
                    .foregroundStyle(audioRecorder.isRecording ? .primary : .tertiary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.default, value: timerString)

                // Record button
                Button(action: toggleRecording) {
                    HStack(spacing: 8) {
                        Image(systemName: audioRecorder.isRecording ? "stop.fill" : "record.circle")
                            .font(.body.weight(.semibold))
                        Text(audioRecorder.isRecording ? "Stop Recording" : "Start Recording")
                            .font(.body.weight(.semibold))
                    }
                    .frame(width: 200, height: 44)
                    .background(audioRecorder.isRecording ? AppTheme.recordingGradient : AppTheme.heroGradient)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(color: (audioRecorder.isRecording ? AppTheme.recording : AppTheme.accent).opacity(0.3), radius: 8, y: 4)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.space, modifiers: [])

                // Subtitle
                if !audioRecorder.isRecording {
                    Text("Press Space to begin")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            // Bottom brand
            HStack(spacing: 6) {
                Image(systemName: "waveform.badge.mic")
                    .foregroundStyle(AppTheme.accent)
                Text("Audio Transcriber 9000")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var timerString: String {
        let duration = audioRecorder.recordingDuration
        let m = (Int(duration) % 3600) / 60
        let s = Int(duration) % 60
        let ms = Int((duration.truncatingRemainder(dividingBy: 1)) * 10)
        return String(format: "%02d:%02d.%d", m, s, ms)
    }

    private func toggleRecording() {
        if audioRecorder.isRecording {
            audioRecorder.stopRecording()
        } else {
            audioRecorder.startRecording()
        }
    }
}
