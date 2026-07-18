import SwiftUI

/// The iCloud Sync settings section (Mac Storage tab + iOS Settings form).
/// Enable runs the migration (compress → copy → verify → repoint) with live
/// status; disable repoints back to the local library without deleting
/// anything from iCloud.
struct CloudSyncSection: View {
    @Environment(RecordingStore.self) private var store
    @Environment(SpeakerLibraryStore.self) private var speakerLibrary
    @Environment(CloudSyncManager.self) private var cloudSync
    @Environment(AudioRecorder.self) private var audioRecorder
    @Environment(TranscriptionService.self) private var transcriptionService

    @State private var migrationStatus: String? = nil
    @State private var migrationError: String? = nil
    @State private var migrationTask: Task<Void, Never>? = nil

    var body: some View {
        Section {
            if cloudSync.isEnabled {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.icloud.fill")
                        .foregroundStyle(AppTheme.success)
                    Text("Syncing with iCloud")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Button("Turn Off") {
                        LibraryMigrator.disableSync(store: store,
                                                    speakerLibrary: speakerLibrary,
                                                    cloudSync: cloudSync)
                    }
                    .buttonStyle(.bordered)
                }
                Text("Recordings, transcripts, summaries, chats, and speaker voices sync through iCloud Drive. Turning off returns to the local library; nothing is deleted from iCloud.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if migrationTask != nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(migrationStatus ?? "Preparing…")
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Cancel") {
                        migrationTask?.cancel()
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                Button {
                    startMigration()
                } label: {
                    Label("Enable iCloud Sync", systemImage: "icloud.and.arrow.up")
                }
                .disabled(!cloudSync.isCloudAvailable)
                if !cloudSync.isCloudAvailable {
                    Text("Sign into iCloud (with iCloud Drive turned on) to enable sync.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Copies your library into iCloud Drive (uncompressed WAVs are converted to AAC first) and keeps every device in sync. The current local library is kept as a backup.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let migrationError {
                Label(migrationError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(AppTheme.warning)
                    .textSelection(.enabled)
            }
        } header: {
            Label("iCloud Sync", systemImage: "icloud")
        }
    }

    private func startMigration() {
        migrationError = nil
        migrationStatus = "Preparing…"
        migrationTask = Task {
            defer { migrationTask = nil }
            do {
                try await LibraryMigrator.enableSync(
                    store: store,
                    speakerLibrary: speakerLibrary,
                    cloudSync: cloudSync,
                    isBusy: audioRecorder.isRecording || transcriptionService.isTranscribing,
                    status: { message in
                        Task { @MainActor in migrationStatus = message }
                    })
            } catch is CancellationError {
                migrationStatus = nil
            } catch {
                migrationError = error.localizedDescription
            }
            migrationStatus = nil
        }
    }
}
