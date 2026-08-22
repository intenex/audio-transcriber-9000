import XCTest

/// Drives the shipped iOS app the way a person does — the only check that
/// covers the two symptoms the user actually reported: the library shows one
/// recording instead of all of them, and pressing Record does nothing.
///
/// Both had the same cause (the launch scan blocked the main thread reading
/// iCloud sidecars, so iOS killed the app at 10 s), and both are invisible to
/// in-process tests: they need the real app, launched normally, with its real
/// library. Deliberately read-only — it opens the recording surface and leaves
/// again without capturing anything into the user's library.
final class RecordFlowUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    private func launchedApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()
        return app
    }

    func testAppLaunchesAndStaysUp() {
        let app = launchedApp()
        XCTAssertTrue(app.navigationBars["Recordings"].waitForExistence(timeout: 20),
                      "the home screen never appeared")
        // The watchdog kills at 10 s of a blocked scene update; the old build
        // never got past this point.
        Thread.sleep(forTimeInterval: 15)
        XCTAssertEqual(app.state, .runningForeground, "the app was killed after launch")
        XCTAssertTrue(app.navigationBars["Recordings"].exists)
    }

    func testTheLibraryListsEverythingItHas() throws {
        let app = launchedApp()
        XCTAssertTrue(app.navigationBars["Recordings"].waitForExistence(timeout: 20))

        // Rows land as the library scan finishes (and, on a fresh device, as
        // the metadata sidecars come down from iCloud).
        let deadline = Date().addingTimeInterval(30)
        var rows = app.cells.count
        while rows < 2 && Date() < deadline {
            Thread.sleep(forTimeInterval: 1)
            rows = app.cells.count
        }
        if rows == 0 {
            // A genuinely empty library says so; that is not this failure.
            try XCTSkipIf(app.staticTexts["No Recordings"].exists,
                          "this device's library is empty — nothing to list")
        }
        XCTAssertGreaterThan(rows, 1,
                             "the library showed \(rows) row(s) — a synced library should list all of them, "
                             + "and showing exactly one was the reported symptom")
    }

    func testPressingRecordOpensTheRecordingSurface() {
        let app = launchedApp()
        XCTAssertTrue(app.navigationBars["Recordings"].waitForExistence(timeout: 20))

        let record = app.buttons["Record"]
        XCTAssertTrue(record.waitForExistence(timeout: 10), "no Record button on the home screen")
        XCTAssertTrue(record.isHittable, "the Record button is on screen but cannot be pressed")
        record.tap()

        XCTAssertTrue(app.buttons["Start Recording"].waitForExistence(timeout: 10),
                      "pressing Record did nothing — the recording surface never came up")
        XCTAssertTrue(app.staticTexts["00:00"].exists || app.staticTexts["0:00"].exists
                      || app.buttons["Start Recording"].exists)

        // Leave without recording: this runs against the real library.
        let done = app.buttons["Done"]
        XCTAssertTrue(done.exists, "no way back out of the recording surface")
        done.tap()
        XCTAssertTrue(app.navigationBars["Recordings"].waitForExistence(timeout: 10))
    }
}
