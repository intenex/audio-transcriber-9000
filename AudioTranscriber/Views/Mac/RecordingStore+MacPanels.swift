import AppKit
import Foundation

/// The Mac-only, panel-driven faces of RecordingStore operations. The store
/// itself stays platform-neutral; iOS drives the same neutral APIs from
/// .fileImporter / confirmationDialog instead.
@MainActor
extension RecordingStore {
    func showInFinder(_ recording: Recording) {
        NSWorkspace.shared.activateFileViewerSelecting([recording.fileURL])
    }

    /// NSOpenPanel import: pick files, resolve the compression policy
    /// (NSAlert when set to ask), then run the shared import.
    func importAudioFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio, .wav, .mp3, .mpeg4Audio, .aiff]
        panel.message = "Select audio files to import for transcription"

        guard panel.runModal() == .OK else { return }
        let urls = panel.urls

        let compress: Bool
        switch resolveImportCompressionPolicy() {
        case .always: compress = true
        case .never: compress = false
        case .ask:
            let estimate = importCompressionEstimate(for: urls)
            compress = estimate.compressibleCount > 0 && askImportCompression(estimate: estimate)
        }
        importAudioFiles(urls: urls, compress: compress)
    }

    private func askImportCompression(
        estimate: (originalBytes: Int64, compressedBytes: Int64, compressibleCount: Int)
    ) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Compress imported audio?"
        alert.informativeText = """
        \(estimate.compressibleCount) file\(estimate.compressibleCount == 1 ? "" : "s") can be converted to high-quality AAC:
        \(ByteCountFormatter.string(fromByteCount: estimate.originalBytes, countStyle: .file)) → ~\(ByteCountFormatter.string(fromByteCount: estimate.compressedBytes, countStyle: .file)).
        Quality remains excellent for listening and transcription. Originals are not modified.
        """
        alert.addButton(withTitle: "Compress")
        alert.addButton(withTitle: "Keep Original Format")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
