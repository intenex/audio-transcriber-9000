// Mac-only: AppKit NSWindow/field-editor driving.
#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import AudioTranscriber

/// In-process end-to-end tests for KeychainSecureField: mounts the real view
/// in a window inside the hosted app and edits through the real field editor
/// (a paste is a single-chunk insertText — identical code path). AX-driven
/// automation cannot focus SwiftUI SecureFields (see docs/TESTING.md), so this
/// is the authoritative verification of the save-on-paste flow.
@MainActor
final class KeychainFieldLiveTests: XCTestCase {

    private var window: NSWindow!
    private var priorValue: String?

    override func setUp() async throws {
        // The test uses the REAL .custom key (same process, same Keychain as
        // the app) — preserve and restore whatever the user has stored.
        priorValue = KeychainStore.shared.get(.custom)
        KeychainStore.shared.delete(.custom)

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 80),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(
            rootView: KeychainSecureField(label: "Test", key: .custom).padding()
        )
        window.makeKeyAndOrderFront(nil)
    }

    override func tearDown() async throws {
        window?.orderOut(nil)
        window = nil
        if let priorValue {
            KeychainStore.shared.set(priorValue, for: .custom)
        } else {
            KeychainStore.shared.delete(.custom)
        }
    }

    private func secureField(in view: NSView) -> NSSecureTextField? {
        if let tf = view as? NSSecureTextField { return tf }
        for sub in view.subviews {
            if let found = secureField(in: sub) { return found }
        }
        return nil
    }

    private func beginEditing() throws -> NSTextView {
        let tf = try XCTUnwrap(secureField(in: window.contentView!), "secure field not found in hierarchy")
        XCTAssertTrue(window.makeFirstResponder(tf))
        return try XCTUnwrap(window.fieldEditor(true, for: tf) as? NSTextView)
    }

    /// Paste path: one-chunk insert → debounced save lands in the Keychain
    /// without Enter or focus change.
    func testPastePersistsWithoutEnter() async throws {
        try await Task.sleep(for: .milliseconds(300))   // let SwiftUI mount + onAppear
        let editor = try beginEditing()
        editor.insertText("test-dummy-key-abc123", replacementRange: NSRange(location: 0, length: 0))
        try await Task.sleep(for: .milliseconds(900))   // > 400 ms debounce
        XCTAssertEqual(KeychainStore.shared.get(.custom), "test-dummy-key-abc123")
    }

    /// The reported regression: any transiently empty field state (mid-paste
    /// reversion, select-all-delete then focus loss) must never destroy a
    /// stored key. Removal is only the explicit ✕ button.
    func testEmptyingFieldDoesNotDeleteStoredKey() async throws {
        try await Task.sleep(for: .milliseconds(300))
        let editor = try beginEditing()
        editor.insertText("keep-me-42", replacementRange: NSRange(location: 0, length: 0))
        try await Task.sleep(for: .milliseconds(900))
        XCTAssertEqual(KeychainStore.shared.get(.custom), "keep-me-42")

        editor.selectAll(nil)
        editor.delete(nil)                               // field now empty
        window.makeFirstResponder(nil)                   // focus loss → commit()
        try await Task.sleep(for: .milliseconds(900))
        XCTAssertEqual(KeychainStore.shared.get(.custom), "keep-me-42",
                       "empty field state must not delete the stored key")
    }
}
#endif
