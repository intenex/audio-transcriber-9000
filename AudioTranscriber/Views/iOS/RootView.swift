#if os(iOS)
import SwiftUI

/// iOS root. Phase-2 bring-up scope: a read-only library list proving the
/// whole shared service graph (store, manifest, meta sidecars) runs on iOS.
/// The full mobile UI (record flow, detail tabs, settings) lands in phase 4+.
struct RootView: View {
    @Environment(RecordingStore.self) private var store
    @Environment(AudioRecorder.self) private var audioRecorder
    @State private var showingRecordSheet = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.recordings) { recording in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(recording.displayName)
                            .font(.body)
                            .lineLimit(1)
                        HStack(spacing: 8) {
                            Label(recording.durationString, systemImage: "clock")
                            Text(recording.formatAndSizeLabel)
                            StatusPill(status: recording.status)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Recordings")
            .overlay {
                if store.recordings.isEmpty {
                    ContentUnavailableView("No Recordings",
                                           systemImage: "waveform",
                                           description: Text("Recordings you make or import will appear here."))
                }
            }
            .safeAreaInset(edge: .bottom) {
                recordButton
            }
            .fullScreenCover(isPresented: $showingRecordSheet) {
                RecordSheet()
            }
        }
    }

    private var recordButton: some View {
        Button {
            showingRecordSheet = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "record.circle")
                    .font(.body.weight(.semibold))
                Text("Record")
                    .font(.body.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(AppTheme.heroGradient)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: AppTheme.accent.opacity(0.3), radius: 8, y: 4)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }
}

/// Full-screen record surface hosting the shared RecordingControlView.
/// Dismissal is blocked while recording — stop first, then leave.
struct RecordSheet: View {
    @Environment(AudioRecorder.self) private var audioRecorder
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            RecordingControlView()
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                            .disabled(audioRecorder.isRecording)
                    }
                }
        }
        .interactiveDismissDisabled(audioRecorder.isRecording)
    }
}
#endif
