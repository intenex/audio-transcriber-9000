import SwiftUI

/// The recording is already safely saved. Closing this sheet keeps it intact.
struct RecordingTrimReview: View {
    let recording: Recording
    @Environment(RecordingStore.self) private var store
    @Environment(AudioRecorder.self) private var recorder
    @State private var cut: Double = 1
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Review and trim recording").font(.title2.bold())
            Text("Listen back, then choose where the recording should end. Everything after that point will be removed only when you click Trim.")
                .foregroundStyle(.secondary)
            Text("Original: \(RecordingClock.display(recording.duration))")
            HStack {
                Button(recorder.isPlaying ? "Pause playback" : "Listen near cut") {
                    if recorder.isPlaying { recorder.stopPlayback() }
                    else { recorder.seekAndPlay(to: max(0, cut - 10), recording: recording) }
                }
                Text(RecordingClock.display(recorder.playbackTime)).monospacedDigit()
            }
            Slider(value: $cut, in: 0.1...max(0.1, recording.duration))
                .accessibilityLabel("Keep audio through")
            HStack {
                Text("Keep through")
                TextField("Seconds", value: $cut, format: .number.precision(.fractionLength(1)))
                    .textFieldStyle(.roundedBorder).frame(width: 110)
                Text("seconds")
                Spacer()
            }
            HStack {
                Text(RecordingClock.display(cut)).monospacedDigit()
                Spacer()
                Button("Use playback position") { cut = max(0.1, min(recording.duration, recorder.playbackTime)) }
                    .disabled(recorder.playingRecordingID != recording.id)
            }
            Text("Remove \(RecordingClock.display(max(0, recording.duration - cut))) from the end")
                .foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Button("Keep Entire Recording") { recorder.stopPlayback(); recorder.finishReview() }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Trim & Save", role: .destructive) {
                    recorder.stopPlayback(); busy = true
                    Task {
                        if await store.truncateReviewedRecording(recording, keeping: cut) { recorder.finishReview() }
                        else { error = store.errorMessage; store.errorMessage = nil }
                        busy = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!cut.isFinite || cut <= 0 || cut >= recording.duration)
            }
        }
        .padding(24)
        .frame(idealWidth: 600)
        .disabled(busy)
        .interactiveDismissDisabled(busy)
        .onAppear { cut = max(0.1, recording.duration) }
        .onDisappear { recorder.stopPlayback() }
    }
}
