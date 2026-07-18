import SwiftUI

/// Small per-row indicator of a recording's iCloud state. Renders nothing in
/// local mode or when the file is downloaded and idle.
struct CloudSyncBadge: View {
    let recording: Recording
    @Environment(CloudSyncManager.self) private var cloudSync

    var body: some View {
        // Reading stateVersion re-evaluates this view when sync states move.
        let _ = cloudSync.stateVersion
        switch cloudSync.state(for: recording) {
        case .placeholder:
            Image(systemName: "icloud.and.arrow.down")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .help("In iCloud — not downloaded on this device")
        case .downloading(let fraction):
            ProgressView(value: fraction)
                .controlSize(.small)
                .frame(width: 40)
        case .uploading:
            Image(systemName: "icloud.and.arrow.up")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .help("Uploading to iCloud")
        case .current, .notTracked:
            EmptyView()
        }
    }
}
