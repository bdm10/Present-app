import XCTest

extension XCUIApplication {
    func element(_ identifier: String) -> XCUIElement {
        descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Finds a text by its visible label, whether exposed alone or inside a combined row.
    func text(containing value: String) -> XCUIElement {
        let exact = staticTexts[value]
        if exact.exists { return exact }
        return descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", value))
            .firstMatch
    }
}

extension XCTestCase {
    /// Keeps a screenshot in the test results (CI exports these for design review).
    func snapshot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}

/// Demo flow: works with no server at all, using the session bundled in the app.
final class DemoFlowUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testDemoPlaybackFromToday() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-PresentResetState", "YES", "-PresentDemoOnly", "YES", "-PresentUITest", "YES"]
        app.launch()

        XCTAssertTrue(app.tabBars.buttons["Today"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.tabBars.buttons["Library"].exists)
        XCTAssertTrue(app.tabBars.buttons["Settings"].exists)
        XCTAssertTrue(app.element("demoBadge").waitForExistence(timeout: 5), "Demo content must be labelled")

        let play = app.buttons["playButton"]
        XCTAssertTrue(play.waitForExistence(timeout: 15))
        snapshot(app, "01-today-demo")
        play.tap()

        XCTAssertTrue(app.element("playerView").waitForExistence(timeout: 10))
        let elapsed = app.staticTexts["elapsedLabel"]
        XCTAssertTrue(elapsed.waitForExistence(timeout: 5))
        let before = elapsed.label
        sleep(3)
        let after = elapsed.label
        if before == after {
            // Some headless simulators have no audio device, so time can't advance.
            // Surface it clearly instead of passing silently.
            XCTContext.runActivity(named: "Elapsed did not advance (\(before)); likely no audio device") { _ in }
        }
        snapshot(app, "02-player")
        XCTAssertNotEqual(before, after, "Elapsed time should advance while playing")

        let pause = app.buttons["playPauseButton"]
        XCTAssertTrue(pause.exists)
        pause.tap()
        let pausedLabel = elapsed.label
        sleep(2)
        XCTAssertEqual(pausedLabel, elapsed.label, "Elapsed time should hold while paused")

        app.buttons["closePlayerButton"].tap()
        XCTAssertTrue(app.element("miniPlayer").waitForExistence(timeout: 5), "Mini player returns to the session")

        // The demo session is in the Library.
        app.tabBars.buttons["Library"].tap()
        XCTAssertTrue(app.buttons["favoriteButton"].waitForExistence(timeout: 5))
        snapshot(app, "03-library-demo")

        app.tabBars.buttons["Settings"].tap()
        sleep(1)
        snapshot(app, "04-settings-demo")
    }
}

/// Server flow: create → generate → play → reflect → journal → favourite.
/// Runs only when a test server is provided (CI passes TEST_RUNNER_PRESENT_TEST_SERVER_URL).
final class ServerFlowUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testCreatePlayReflectFavourite() throws {
        let env = ProcessInfo.processInfo.environment
        guard let serverURL = env["PRESENT_TEST_SERVER_URL"], !serverURL.isEmpty else {
            throw XCTSkip("Set PRESENT_TEST_SERVER_URL (and PRESENT_TEST_TOKEN) to run the server flow.")
        }
        let token = env["PRESENT_TEST_TOKEN"] ?? "test-token"

        let app = XCUIApplication()
        app.launchArguments = [
            "-PresentResetState", "YES",
            "-PresentServerURL", serverURL,
            "-PresentToken", token,
            "-PresentFastFinish", "YES",
            "-PresentUITest", "YES",
        ]
        app.launch()

        // Dismiss the notification permission prompt if it appears.
        addUIInterruptionMonitor(withDescription: "Notifications") { alert in
            let allow = alert.buttons["Allow"]
            if allow.exists { allow.tap(); return true }
            return false
        }

        let newSession = app.buttons["newSessionButton"]
        XCTAssertTrue(newSession.waitForExistence(timeout: 30))
        newSession.tap()

        let fiveMinutes = app.buttons["durationPill_5"]
        XCTAssertTrue(fiveMinutes.waitForExistence(timeout: 10))
        fiveMinutes.tap()
        app.buttons["themePill_gratitude"].tap()
        snapshot(app, "10-new-session-sheet")

        let create = app.buttons["createSessionButton"]
        create.tap()
        // The sheet closes once the server has accepted the request.
        let sheetGone = NSPredicate(format: "exists == false")
        expectation(for: sheetGone, evaluatedWith: create)
        waitForExpectations(timeout: 30)

        // Generation (demo providers on CI) then download.
        let play = app.buttons["playButton"]
        XCTAssertTrue(play.waitForExistence(timeout: 180), "Session should become ready")
        let title = app.staticTexts["todayTitle"].label
        XCTAssertFalse(title.isEmpty)
        snapshot(app, "11-today-server")
        play.tap()

        // Fast-finish ends playback after ~3 s and the reflection appears.
        XCTAssertTrue(app.element("reflectionView").waitForExistence(timeout: 60))
        let editor = app.textViews["journalEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        let note = "Grateful for a slow breakfast."
        editor.typeText(note)
        snapshot(app, "12-reflection")
        app.buttons["saveReflectionButton"].tap()
        let closed = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.element("reflectionView"))
        wait(for: [closed], timeout: 10)
        sleep(1) // let the finished session's mini player go away

        // Library: open this session (the server may also have made today's daily one),
        // favourite it from its detail page, and check the private journal entry is there.
        app.tabBars.buttons["Library"].tap()
        let row = app.text(containing: title)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Session should be listed in the Library")
        row.tap()
        let detailHeart = app.buttons["detailFavoriteButton"]
        XCTAssertTrue(detailHeart.waitForExistence(timeout: 10))
        detailHeart.tap()
        let entry = app.text(containing: note)
        if !entry.waitForExistence(timeout: 5) {
            app.swipeUp()
        }
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "Journal entry should show on the session")
        snapshot(app, "13-session-detail")

        // Back to the list: the session now appears under Favourites.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.segmentedControls.buttons["Favourites"].tap()
        XCTAssertTrue(app.text(containing: title).waitForExistence(timeout: 10), "Favourited session appears in Favourites")
        snapshot(app, "14-library-favourites")

        app.tabBars.buttons["Settings"].tap()
        sleep(2)
        snapshot(app, "15-settings-server")
    }
}
