import XCTest
@testable import AudioTranscriber
final class AudioCaptureStartupTests: XCTestCase {
    func testBlockedStartupTimesOutAndCleansUpItsLateResult() async {
        let cleaned = expectation(description: "late device is torn down")
        let started = Date()
        do {
            _ = try await AudioCaptureStartup.run(timeout: 0.03, operation: {
                Thread.sleep(forTimeInterval: 0.3); return 42
            }, discard: { value in XCTAssertEqual(value, 42); cleaned.fulfill() })
            XCTFail("a blocked device must not leave the recording button stuck")
        } catch { XCTAssertLessThan(Date().timeIntervalSince(started), 0.25) }
        await fulfillment(of: [cleaned], timeout: 1)
    }
    func testAsyncStartupDeadlineCleansUpAnUncancellableLateResult() async {
        let cleaned = expectation(description: "late stream is stopped")
        do {
            _ = try await AudioCaptureStartup.runAsync(timeout: 0.03, operation: {
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { continuation.resume(returning: 7) }
                }
            }, discard: { value in XCTAssertEqual(value, 7); cleaned.fulfill() })
            XCTFail("permission and capture-service waits need a deadline")
        } catch { }
        await fulfillment(of: [cleaned], timeout: 1)
    }

}
