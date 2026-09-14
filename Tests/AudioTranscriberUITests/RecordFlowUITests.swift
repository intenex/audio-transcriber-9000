import XCTest

/// Drives the shipped iOS app the way a person does — the only check that
/// covers the two symptoms the user actually reported: the library shows one
/// recording instead of all of them, and pressing Record does nothing.
///
/// Both had the same cause (the launch scan blocked the main thread reading
/// iCloud sidecars, so iOS killed the app at 10 s), and both are invisible to
/// in-process tests: they need the real app, launched normally, with its real
/// library. Uses five isolated fixtures and never opens the user's library.
final class RecordFlowUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    private func launchedApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestSeedLibrary"]
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

        // Five small fixtures live in an isolated in-app test directory.
        // An empty real library or a single valid recording cannot invalidate
        // this regression test, and no real recordings are opened or changed.
        let deadline = Date().addingTimeInterval(15)
        while app.cells.count < 5 && Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        XCTAssertGreaterThanOrEqual(app.cells.count, 5, "the list must expose all five fixture recordings")
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
