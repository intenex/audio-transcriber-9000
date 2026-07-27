import Foundation
import UserNotifications
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Notifications about a recording that is still running: the long-recording
/// check-in ("still recording?") and the silence auto-stop notice.
///
/// These exist for the case where the app is NOT in front — the situation that
/// let a recording run unattended for 70 hours. The check-in banner carries
/// Keep Recording / Stop & Save actions so the answer never requires finding
/// the window.
final class RecordingNotifier: NSObject {
    static let shared = RecordingNotifier()

    static let checkInCategory = "recording-check-in"
    static let keepActionID = "recording-keep"
    static let stopActionID = "recording-stop"
    private static let checkInRequestID = "recording-check-in-request"
    private static let autoStopRequestID = "recording-auto-stopped"

    private weak var recorder: AudioRecorder?
    private var didRequestAuthorization = false

    /// Notification APIs are noisy and permission-prompting under XCTest.
    private var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// Called once from AppBootstrap; owns the notification-center delegate so
    /// banner actions can reach the recorder.
    @MainActor
    func activate(recorder: AudioRecorder) {
        self.recorder = recorder
        guard !isRunningTests else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let keep = UNNotificationAction(identifier: Self.keepActionID,
                                        title: "Keep Recording", options: [])
        let stop = UNNotificationAction(identifier: Self.stopActionID,
                                        title: "Stop & Save", options: [.destructive])
        let category = UNNotificationCategory(identifier: Self.checkInCategory,
                                              actions: [keep, stop],
                                              intentIdentifiers: [], options: [])
        center.setNotificationCategories([category])
    }

    func requestAuthorizationIfNeeded() {
        guard !isRunningTests, !didRequestAuthorization else { return }
        didRequestAuthorization = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // MARK: - Posting

    func postCheckIn(elapsed: TimeInterval) {
        guard !isRunningTests else { return }
        let content = UNMutableNotificationContent()
        content.title = "Still recording?"
        content.body = "This recording has been running for \(Self.durationText(elapsed)). Keep going?"
        content.sound = .default
        content.categoryIdentifier = Self.checkInCategory
        content.interruptionLevel = .timeSensitive
        let request = UNNotificationRequest(identifier: Self.checkInRequestID, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    func clearCheckIn() {
        guard !isRunningTests else { return }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.checkInRequestID])
        center.removeDeliveredNotifications(withIdentifiers: [Self.checkInRequestID])
    }

    func postAutoStopped(message: String) {
        guard !isRunningTests else { return }
        let content = UNMutableNotificationContent()
        content.title = "Recording stopped and saved"
        content.body = message
        content.sound = .default
        let request = UNNotificationRequest(identifier: Self.autoStopRequestID, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    /// "2h 5m" / "45m" — compact enough for a banner title line.
    static func durationText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension RecordingNotifier: UNUserNotificationCenterDelegate {
    /// The in-app alert covers the foreground case; don't double up there.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler:
                                @escaping (UNNotificationPresentationOptions) -> Void) {
        #if os(macOS)
        let appIsActive = NSApp?.isActive ?? false
        #else
        let appIsActive = UIApplication.shared.applicationState == .active
        #endif
        if appIsActive, notification.request.content.categoryIdentifier == Self.checkInCategory {
            completionHandler([])
        } else {
            completionHandler([.banner, .sound])
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        Task { @MainActor [weak self] in
            guard let recorder = self?.recorder else { return }
            switch action {
            case Self.keepActionID:
                recorder.acknowledgeCheckIn()
            case Self.stopActionID:
                recorder.stopRecordingFromCheckIn()
            default:
                break   // tapping the banner just brings the app forward
            }
            completionHandler()
        }
    }
}
