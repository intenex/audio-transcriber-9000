import Foundation

/// Prevents idle system sleep while alive (recording or transcribing).
/// Drop the reference (or let it deinit) to end the assertion.
final class SleepGuard {
    private let activity: NSObjectProtocol

    init(reason: String) {
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: reason
        )
    }

    deinit {
        ProcessInfo.processInfo.endActivity(activity)
    }
}
