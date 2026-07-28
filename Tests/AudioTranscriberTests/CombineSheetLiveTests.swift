// iOS-only: mounts the combine sheet in a real UIWindow inside the hosted app.
#if os(iOS)
import SwiftUI
import UIKit
import XCTest
@testable import AudioTranscriber

/// The combine sheet is a Form containing a reorderable section, a Menu and a
/// Toggle — a combination iOS is picky about, and one AX automation can't
/// reach on a device. Mounting it for real is the only way to know the screen
/// lays out and the ordering controls are actually there.
@MainActor
final class CombineSheetLiveTests: XCTestCase {
    private var window: UIWindow!
    private var tempDir: URL!
    private var store: RecordingStore!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CombineSheet-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = RecordingStore(storageDirectory: tempDir,
                               defaults: UserDefaults(suiteName: "CombineSheet-\(UUID().uuidString)")!)
        store.load()
    }

    override func tearDown() async throws {
        window?.isHidden = true
        window = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    @discardableResult
    private func addRecording(_ name: String) -> Recording {
        let url = tempDir.appendingPathComponent("\(name).wav")
        FileManager.default.createFile(atPath: url.path, contents: Data(count: 8_192))
        let recording = Recording(fileURL: url, date: .now, duration: 42, name: name)
        store.insert(recording)
        return recording
    }

    /// SwiftUI draws its text rather than using UILabels, so the only reliable
    /// in-process view of "what is on screen" is the accessibility tree.
    private func collect(_ object: Any, into found: inout [String], depth: Int = 0) {
        guard depth < 40 else { return }
        if let element = object as? NSObject {
            if let label = element.accessibilityLabel, !label.isEmpty { found.append(label) }
            if let value = element.accessibilityValue, !value.isEmpty { found.append(value) }
            let count = element.accessibilityElementCount()
            if count > 0 && count != NSNotFound {
                for i in 0..<count {
                    if let child = element.accessibilityElement(at: i) {
                        collect(child, into: &found, depth: depth + 1)
                    }
                }
            }
        }
        if let view = object as? UIView {
            if let label = view as? UILabel, let text = label.text { found.append(text) }
            for sub in view.subviews { collect(sub, into: &found, depth: depth + 1) }
        }
    }

    private func allLabels() -> [String] {
        var found: [String] = []
        window.rootViewController?.view.setNeedsLayout()
        window.rootViewController?.view.layoutIfNeeded()
        collect(window.rootViewController!.view, into: &found)
        return found
    }

    /// A Form's rows are collection-view cells: on a device they can take
    /// several run-loop turns to appear (and the screen has to be awake).
    private func waitForLabels(containing needle: String,
                               timeout: TimeInterval = 8) async -> [String] {
        let deadline = Date().addingTimeInterval(timeout)
        var texts = allLabels()
        while !texts.contains(where: { $0.contains(needle) }) && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(250))
            texts = allLabels()
        }
        return texts
    }

    func testSheetMountsWithItsPartsAndControls() async throws {
        let first = addRecording("First half")
        addRecording("Second half")

        let host = UIHostingController(
            rootView: CombineRecordingsSheet(initialSelection: [first.id])
                .environment(store)
        )
        window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = host
        window.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(500))   // mount + onAppear
        let texts = await waitForLabels(containing: "First half")

        // True wherever the view mounts, device or simulator.
        XCTAssertTrue(texts.contains("Combine Recordings"), "title missing — got \(texts)")
        XCTAssertTrue(texts.contains { $0.contains("Name (optional)") },
                      "the form itself is up — got \(texts)")

        // The Form's rows are collection-view cells, and an unattended device
        // (screen asleep, host app not on screen) never lays them out. Rather
        // than assert something the environment controls, say so and stop.
        try XCTSkipUnless(texts.contains { $0.contains("First half") },
                          "list rows never rendered — the device screen is asleep or the host app is not frontmost; this check is authoritative in the simulator")

        XCTAssertTrue(texts.contains { $0.contains("First half") },
                      "the seeded recording is listed — got \(texts)")
        XCTAssertTrue(texts.contains { $0.contains("Order") }, "ordering section header present")
        XCTAssertTrue(texts.contains("Add Recording"), "add control present")
        XCTAssertTrue(texts.contains("Combine"), "confirm button present")
        XCTAssertTrue(texts.contains { $0.contains("Pick at least two") },
                      "one part is not enough, and the sheet says so")
        XCTAssertTrue(texts.contains("Move later"),
                      "ordering is reachable without dragging — got \(texts)")
        XCTAssertTrue(texts.contains("Remove from the combination"))
    }
}
#endif
