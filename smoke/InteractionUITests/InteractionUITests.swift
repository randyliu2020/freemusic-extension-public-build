import XCTest
import XCUIAutomation

/// A standalone XCTest runner controls ONLY the preinstalled self-authored
/// org.codex.fmx.smoke app. It never installs or launches the user's IPA.
final class InteractionUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    private func app(_ fixture: String) -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "org.codex.fmx.smoke")
        app.launchArguments = ["--ui-fixture=\(fixture)"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 12))
        return app
    }

    @MainActor
    private func record(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testSingleLyricTapSeeksWithoutExpandingAndDoubleTapExpands() throws {
        let app = app("lyrics")
        defer { app.terminate() }
        let line = app.staticTexts["smoke.interaction.lyric.1"]
        XCTAssertTrue(line.waitForExistence(timeout: 12))
        XCTAssertTrue(line.isHittable)
        line.tap()
        let count = app.staticTexts["smoke.interaction.seek-count"]
        let once = NSPredicate(format: "label == %@", "Seek count: 1")
        expectation(for: once, evaluatedWith: count)
        waitForExpectations(timeout: 5)
        // SwiftUI's localized numeric interpolation controls decimal precision.
        // Assert the chosen time, not a particular number of trailing zeroes.
        let selected = app.staticTexts["smoke.interaction.selected-time"].label
        XCTAssertNotNil(selected.range(of: #"^Selected: 37([.,]0+)?$"#, options: .regularExpression), selected)
        XCTAssertFalse(app.staticTexts["smoke.interaction.full-lyrics"].exists)
        record("one actual tap seeks in preview without presenting another page", app: app)
        line.doubleTap()
        XCTAssertTrue(app.staticTexts["smoke.interaction.full-lyrics"].waitForExistence(timeout: 5))
        record("two actual taps expand the full lyrics page", app: app)
    }

    @MainActor
    func testRealDragDismissesKeyboardInSwiftUISearchResults() throws {
        let app = app("swiftui-search")
        defer { app.terminate() }
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 12))
        search.tap()
        search.typeText("fixture")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        record("real search keyboard before dragging", app: app)
        // Coordinates are restricted to this self-authored UI test surface;
        // production code does not intercept coordinates or synthesize touches.
        let list = app.collectionViews.firstMatch.exists ? app.collectionViews.firstMatch : app.tables.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        let end = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.60))
        start.press(forDuration: 0.05, thenDragTo: end)
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: app.keyboards.firstMatch)
        waitForExpectations(timeout: 5)
        record("real drag dismissed the keyboard", app: app)
    }

    @MainActor
    func testPlayerTopBarLeftSwipeReturnsAndReopensWithoutStealingControls() throws {
        let app = app("player-swipe")
        defer { app.terminate() }
        let open = app.buttons["smoke.interaction.open-player"]
        XCTAssertTrue(open.waitForExistence(timeout: 12))
        open.tap()
        let visible = app.staticTexts["smoke.interaction.player-visible"]
        XCTAssertTrue(visible.waitForExistence(timeout: 5))
        let bar = app.descendants(matching: .any).matching(identifier: "smoke.interaction.player-topbar").firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 5))

        // Real horizontal interaction outside the gesture subtree must remain
        // on the player. No synthetic callback establishes this assertion.
        for identifier in ["smoke.interaction.player-progress", "smoke.interaction.player-volume"] {
            let slider = app.sliders[identifier]
            XCTAssertTrue(slider.exists)
            let before = slider.value as? String
            let start = slider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let end = slider.coordinate(withNormalizedOffset: CGVector(dx: 0.10, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: end)
            XCTAssertTrue(visible.exists)
            XCTAssertNotEqual(slider.value as? String, before, "The actual slider receives its drag")
        }
        let horizontal = app.scrollViews["smoke.interaction.player-horizontal"]
        XCTAssertTrue(horizontal.exists)
        horizontal.swipeLeft()
        XCTAssertTrue(visible.exists)
        let lyrics = app.scrollViews["smoke.interaction.player-lyrics"]
        XCTAssertTrue(lyrics.exists)
        let firstLine = app.staticTexts["smoke.interaction.scroll-lyric.0"]
        XCTAssertTrue(firstLine.isHittable)
        lyrics.swipeUp()
        XCTAssertTrue(visible.exists)
        XCTAssertFalse(firstLine.isHittable, "Vertical lyrics still scroll")
        record("sliders horizontal content and vertical lyrics keep their own gestures", app: app)

        let start = bar.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
        let end = bar.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end)
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "label == %@", "Closed: 1"),
                    evaluatedWith: app.staticTexts["smoke.interaction.player-close-count"])
        waitForExpectations(timeout: 5)
        XCTAssertEqual(app.staticTexts["smoke.interaction.player-binding"].label, "Player binding: false")
        XCTAssertEqual(app.staticTexts["smoke.interaction.player-close-count"].label, "Closed: 1")
        record("left swipe returns with the presentation binding cleared", app: app)
        open.tap()
        XCTAssertTrue(visible.waitForExistence(timeout: 5), "The same original opener must work again")

        // The previous top-bar downward close remains available after reopening.
        let downStart = bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        let downEnd = downStart.withOffset(CGVector(dx: 0, dy: 140))
        downStart.press(forDuration: 0.05, thenDragTo: downEnd)
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "label == %@", "Closed: 2"),
                    evaluatedWith: app.staticTexts["smoke.interaction.player-close-count"])
        waitForExpectations(timeout: 5)
        XCTAssertEqual(app.staticTexts["smoke.interaction.player-binding"].label, "Player binding: false")
        XCTAssertEqual(app.staticTexts["smoke.interaction.player-close-count"].label, "Closed: 2")
        record("reopened player preserves its original downward close", app: app)
    }
}
