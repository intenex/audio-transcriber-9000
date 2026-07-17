import SwiftUI

struct RecordingControlView: View {
    @Environment(AudioRecorder.self) private var audioRecorder
    @Environment(LiveTranscriber.self) private var liveTranscriber

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

            // Live transcript preview while recording
            if audioRecorder.isRecording && liveTranscriber.isRunning {
                livePreview
                    .padding(.top, 24)
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

    private var livePreview: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if liveTranscriber.displayText.isEmpty {
                        Text("Listening…")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                    } else {
                        (Text(liveTranscriber.confirmedText)
                            .foregroundStyle(.primary)
                         + Text(liveTranscriber.volatileText)
                            .foregroundStyle(.secondary))
                            .font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Color.clear.frame(height: 1).id("live-end")
                }
                .padding(14)
            }
            .onChange(of: liveTranscriber.displayText) { _, _ in
                proxy.scrollTo("live-end", anchor: .bottom)
            }
        }
        .frame(maxWidth: 520, maxHeight: 140)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(alignment: .topLeading) {
            Label("Live preview", systemImage: "waveform")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .padding(.top, -8)
                .padding(.leading, 10)
                .background(.background.opacity(0.01))
        }
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
