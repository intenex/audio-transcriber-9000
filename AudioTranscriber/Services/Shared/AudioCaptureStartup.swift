import Foundation

/// HAL calls can block indefinitely (for example during a Bluetooth handoff).
/// Keep them off the cooperative pool and bound the UI wait independently.
enum AudioCaptureStartup {
    private static let slots = DispatchSemaphore(value: 2)
    private final class Attempt<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Value, Error>?
        init(_ continuation: CheckedContinuation<Value, Error>) { self.continuation = continuation }
        @discardableResult func complete(_ result: Result<Value, Error>) -> Bool {
            lock.lock(); let pending = continuation; continuation = nil; lock.unlock()
            guard let pending else { return false }
            pending.resume(with: result); return true
        }
    }
    static func run<Value>(timeout: TimeInterval = 15,
                           operation: @escaping @Sendable () throws -> Value,
                           discard: @escaping @Sendable (Value) -> Void) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            let attempt = Attempt(continuation)
            DispatchQueue.global(qos: .userInitiated).async {
                guard slots.wait(timeout: .now()) == .success else {
                    attempt.complete(.failure(NSError(domain: "AudioCapture", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "The audio system is still reconnecting. Reconnect your audio device before trying again."])))
                    return
                }
                defer { slots.signal() }
                do {
                    let value = try operation()
                    if !attempt.complete(.success(value)) { discard(value) }
                } catch { attempt.complete(.failure(error)) }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                attempt.complete(.failure(NSError(domain: "AudioCapture", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "The audio device did not respond in time. Reconnect it and try again. Any captured audio is preserved."])))
            }
        }
    }
    /// The same deadline for asynchronous capture APIs, without blocking a
    /// thread while macOS presents permission or reconnects its capture service.
    static func runAsync<Value>(timeout: TimeInterval = 15,
                                operation: @escaping @Sendable () async throws -> Value,
                                discard: @escaping @Sendable (Value) -> Void) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            let attempt = Attempt(continuation)
            let task = Task.detached(priority: .userInitiated) {
                guard slots.wait(timeout: .now()) == .success else {
                    attempt.complete(.failure(NSError(domain: "AudioCapture", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "The audio system is still reconnecting. Try again shortly."])))
                    return
                }
                defer { slots.signal() }
                do {
                    let value = try await operation()
                    if !attempt.complete(.success(value)) { discard(value) }
                } catch { attempt.complete(.failure(error)) }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                if attempt.complete(.failure(NSError(domain: "AudioCapture", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Audio capture did not respond in time. Check recording permission and try again. Any captured audio is preserved."]))) {
                    task.cancel()
                }
            }
        }
    }

}
