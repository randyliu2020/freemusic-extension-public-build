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
            if identifier.hasSuffix("progress") {
                // The knob is now in the left third. A drag that started on
                // this control must not turn into a full-player dismissal.
                end.press(forDuration: 0.05, thenDragTo: end.withOffset(CGVector(dx: 16, dy: 180)))
                XCTAssertTrue(visible.exists, "A downward drag beginning on the progress control stays in the player")
            }
        }
        let horizontal = app.scrollViews["smoke.interaction.player-horizontal"]
        XCTAssertTrue(horizontal.exists)
        horizontal.swipeLeft()
        XCTAssertTrue(visible.exists)
        let lyrics = app.scrollViews["smoke.interaction.player-lyrics"]
        XCTAssertTrue(lyrics.exists)
        let firstLine = app.descendants(matching: .any).matching(identifier: "smoke.interaction.scroll-lyric.0").firstMatch
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

        open.tap()
        XCTAssertTrue(visible.waitForExistence(timeout: 5))
        firstLine.tap()
        XCTAssertEqual(visible.label, "Selected lyric 0")
        let page = app.frame
        let third = page.width / 3
        let leftCut = page.minX + third
        let rightCut = page.maxX - third

        func at(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x - page.minX, dy: y - page.minY))
        }
        func measuredWord(_ index: Int) throws -> CGRect {
            // Independent fixture measurements of the rendered Text before its
            // full-width tappable row. These measurements cannot dismiss a view.
            let ready = expectation(for: NSPredicate(format: "value MATCHES %@", #"[^|]+\|[^|]+\|[^|]+\|[^|]+"#),
                                    evaluatedWith: visible)
            wait(for: [ready], timeout: 5)
            let encoded = try XCTUnwrap(visible.value as? String)
            let parts = encoded.components(separatedBy: "|")
            XCTAssertEqual(parts.count, 4)
            guard parts.count == 4 else { throw NSError(domain: "LyricFixture", code: 1) }
            XCTAssertEqual(parts[3], "exact third cutoffs passed")
            let numbers = parts[index].split(separator: ",").compactMap { Double($0) }.map { CGFloat($0) }
            XCTAssertEqual(numbers.count, 4)
            guard numbers.count == 4 else { throw NSError(domain: "LyricFixture", code: 2) }
            let viewport = lyrics.frame
            let rect = CGRect(x: viewport.minX + numbers[0], y: viewport.minY + numbers[1],
                              width: numbers[2], height: numbers[3])
            XCTAssertGreaterThan(rect.width, 8)
            XCTAssertGreaterThan(rect.height, 8)
            return rect
        }
        func assertReturned(_ count: Int, _ reason: String) {
            XCTAssertTrue(open.waitForExistence(timeout: 5), reason)
            let label = app.staticTexts["smoke.interaction.player-close-count"]
            let expected = expectation(for: NSPredicate(format: "label == %@", "Closed: \(count)"), evaluatedWith: label)
            wait(for: [expected], timeout: 5)
            XCTAssertEqual(app.staticTexts["smoke.interaction.player-binding"].label, "Player binding: false")
            XCTAssertEqual(app.staticTexts["smoke.interaction.audio-state"].label, "Playing; starts=1")
        }

        let short = try measuredWord(2)
        let middleX = leftCut + 7
        // This x is central for the full player but in the LEFT third of the
        // inset lyric viewport. It is visibly to the left of the short Text.
        XCTAssertLessThan(middleX, lyrics.frame.minX + lyrics.frame.width / 3 - 5)
        XCTAssertLessThan(middleX, short.minX - 6)
        XCTAssertTrue(lyrics.frame.contains(CGPoint(x: middleX, y: short.midY)))
        let up = at(middleX, short.midY)
        let lift = min(short.midY - lyrics.frame.minY - 14, 78)
        XCTAssertGreaterThan(lift, 46)
        up.press(forDuration: 0.05, thenDragTo: up.withOffset(CGVector(dx: 0, dy: -lift)),
                 withVelocity: .slow, thenHoldForDuration: 0.25)
        XCTAssertTrue(visible.exists)
        let raised = try measuredWord(2)
        XCTAssertLessThan(raised.midY, short.midY - 24, "The center scrolls up from the blank next to a short line")
        XCTAssertTrue(lyrics.frame.contains(CGPoint(x: middleX, y: raised.midY)))
        let center = at(middleX, raised.midY)
        center.press(forDuration: 0.05, thenDragTo: at(leftCut - 35, raised.midY + 185),
                     withVelocity: .slow, thenHoldForDuration: 0.25)
        XCTAssertTrue(visible.exists, "Starting in the middle cannot dismiss by crossing into a side")
        let lowered = try measuredWord(2)
        XCTAssertGreaterThan(lowered.midY, raised.midY + 24, "The center scrolls back down")
        let titleSpace = visible.frame.midY
        let centerOutsideLyrics = at(rightCut - 6, titleSpace)
        centerOutsideLyrics.press(forDuration: 0.05, thenDragTo: centerOutsideLyrics.withOffset(CGVector(dx: 0, dy: 185)))
        XCTAssertTrue(visible.exists, "Down in the middle outside the lyrics also leaves the player open")

        for i in 0..<2 {
            let word = try measuredWord(i)
            let x = word.midX, y = word.midY
            if i == 0 { XCTAssertLessThan(x, leftCut - 4) }
            else { XCTAssertGreaterThan(x, rightCut + 4) }
            XCTAssertTrue(lyrics.frame.contains(CGPoint(x: x, y: y)))
            let startOnText = at(x, y)
            startOnText.press(forDuration: 0.05, thenDragTo: at(x, y + 48))
            XCTAssertTrue(visible.exists, "A short vertical drag must not collapse")
            let sideToCenter = i == 0 ? leftCut + 15 : rightCut - 15
            startOnText.press(forDuration: 0.05, thenDragTo: at(sideToCenter, y + 12))
            XCTAssertTrue(visible.exists, "A mostly horizontal lyric gesture must not collapse")
            // The gesture starts on text inside a side third and ends inside
            // the central third. No text bounds may veto a side dismissal.
            let down = max(184, 2 * abs(x - sideToCenter) + 16)
            startOnText.press(forDuration: 0.05, thenDragTo: at(sideToCenter, y + down))
            assertReturned(3 + i, "Downward drag from a word in side third \(i) closes the full player")
            open.tap()
            XCTAssertTrue(visible.waitForExistence(timeout: 5))
        }
        // The band above the words has no lyric gesture. Only the page-level
        // gesture can dismiss here, while the original audio player keeps going.
        let outside = at(page.minX + third * 0.55, visible.frame.midY)
        XCTAssertLessThan(visible.frame.midY, lyrics.frame.minY)
        outside.press(forDuration: 0.05, thenDragTo: outside.withOffset(CGVector(dx: 0, dy: 185)))
        assertReturned(5, "An outer third works even when the drag starts outside the lyrics")
        record("page thirds keep center scrolling; either side returns with the original audio playing", app: app)
    }
}
