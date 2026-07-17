import Foundation
#if os(iOS)
import UIKit
#endif

/// Prevents idle sleep while alive (recording or transcribing). Drop the
/// reference (or let it deinit) to end the assertion.
///
/// macOS: a ProcessInfo activity assertion. iOS: a refcount driving
/// `UIApplication.isIdleTimerDisabled` — the recorder and the transcription
/// queue can hold guards simultaneously, so a plain bool would clobber.
final class SleepGuard {
    #if os(macOS)
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
    #else
    @MainActor private static var holders = 0

    init(reason: String) {
        Task { @MainActor in
            Self.holders += 1
            UIApplication.shared.isIdleTimerDisabled = true
        }
    }

    deinit {
        Task { @MainActor in
            Self.holders = max(0, Self.holders - 1)
            if Self.holders == 0 {
                UIApplication.shared.isIdleTimerDisabled = false
            }
        }
    }
    #endif
}
