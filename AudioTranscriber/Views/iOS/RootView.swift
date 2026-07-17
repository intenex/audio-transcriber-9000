#if os(iOS)
import SwiftUI

/// iOS root. Phase-2 bring-up scope: a read-only library list proving the
/// whole shared service graph (store, manifest, meta sidecars) runs on iOS.
/// The full mobile UI (record flow, detail tabs, settings) lands in phase 4+.
struct RootView: View {
    @Environment(RecordingStore.self) private var store

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
        }
    }
}
#endif
