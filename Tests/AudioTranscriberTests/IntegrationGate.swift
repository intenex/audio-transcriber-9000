import Foundation

/// Marker-file gate for tests that need real hardware/models.
///
/// macOS: `touch /tmp/audiotranscriber-integration-tests`.
/// iOS (real device or simulator): the sandbox can't see `/tmp`, so the same
/// file name inside the app's Documents container counts too — that container
/// is reachable from the Mac with
/// `xcrun devicectl device copy to --domain-type appDataContainer
///  --domain-identifier com.audiortranscriber.AudioTranscriber.ios
///  --source <marker> --destination Documents/audiotranscriber-integration-tests`
enum IntegrationGate {
    static let markerName = "audiotranscriber-integration-tests"

    static var isEnabled: Bool {
        if FileManager.default.fileExists(atPath: "/tmp/\(markerName)") { return true }
        guard let documents = FileManager.default.urls(for: .documentDirectory,
                                                       in: .userDomainMask).first else { return false }
        return FileManager.default.fileExists(atPath: documents.appendingPathComponent(markerName).path)
    }
}
