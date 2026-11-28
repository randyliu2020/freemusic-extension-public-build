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
        // Both horizontal test positions are farther from the viewport edge
        // than the old 24/32-point gutters. Long and short lyrics share these x values.
        // X uses the visible scroll viewport; y uses the displayed text element.
        func lyricText(_ index: Int) -> XCUIElement {
            app.descendants(matching: .any).matching(identifier: "smoke.interaction.lyric-text.\(index)").firstMatch
        }
        func insetX(right: Bool) -> CGFloat {
            let bounds = lyrics.frame
            let inset = max(64, bounds.width * 0.26)
            XCTAssertGreaterThan(inset, 32)
            return right ? bounds.maxX - inset : bounds.minX + inset
        }
        func point(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
            let viewport = lyrics.frame
            return lyrics.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x - viewport.minX,
                                                                                    dy: y - viewport.minY))
        }
        func firstTextLineY(_ element: XCUIElement) -> CGFloat {
            let rect = element.frame
            // Long lyric fixtures start with a filled visual line, followed by
            // a wrap. The AX bounding box alone cannot describe the second line.
            return rect.minY + min(12, rect.height / 2)
        }
        func assertLongTextContains(_ x: CGFloat, _ element: XCUIElement) {
            XCTAssertTrue(element.waitForExistence(timeout: 5))
            XCTAssertGreaterThan(x, element.frame.minX + 5)
            XCTAssertLessThan(x, element.frame.maxX - 5)
        }
        // Start on a short line, then on a wrapped lyric. Large downward text
        // drags must deliver real scrolling too, including at the top boundary.
        let short = app.descendants(matching: .any).matching(identifier: "smoke.interaction.scroll-lyric.2").firstMatch
        let shortStart = short.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        shortStart.press(forDuration: 0.05, thenDragTo: shortStart.withOffset(CGVector(dx: 0, dy: 160)))
        XCTAssertTrue(visible.exists)
        let firstText = lyricText(0)
        let rightX = insetX(right: true)
        assertLongTextContains(rightX, firstText)
        let wrappedStart = point(rightX, firstTextLineY(firstText))
        let rightEdge = lyrics.frame.maxX - 12
        let fall = max(185, 2 * (rightEdge - rightX) + 12)
        wrappedStart.press(forDuration: 0.05, thenDragTo: point(rightEdge, firstTextLineY(firstText) + fall))
        XCTAssertTrue(visible.exists, "A gesture beginning on the long lyric stays in the player even when it ends in a gutter")
        let translation = app.descendants(matching: .any).matching(identifier: "smoke.interaction.lyric-translation.1").firstMatch
        let translationX = insetX(right: false)
        assertLongTextContains(translationX, translation)
        let translatedStart = point(translationX, firstTextLineY(translation))
        translatedStart.press(forDuration: 0.05, thenDragTo: translatedStart.withOffset(CGVector(dx: 0, dy: 175)))
        XCTAssertTrue(visible.exists, "Text in the translation below a shorter lyric is also a scrolling surface")
        let middle = lyrics.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.82))
        middle.press(forDuration: 0.05, thenDragTo: middle.withOffset(CGVector(dx: 0, dy: -155)))
        XCTAssertFalse(firstLine.isHittable)
        let above = lyrics.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15))
        // Scroll back until the first row becomes hittable, proving downward
        // motion travels to the scroll view instead of just suppressing close.
        for _ in 0..<8 where !firstLine.isHittable {
            above.press(forDuration: 0.05, thenDragTo: above.withOffset(CGVector(dx: 0, dy: 175)))
            XCTAssertTrue(visible.exists)
        }
        XCTAssertTrue(firstLine.isHittable)

        for (index, right) in [false, true].enumerated() {
            let top = lyrics.coordinate(withNormalizedOffset: CGVector(dx: right ? 1 : 0, dy: 0.13))
            // Second opening uses regular lyrics. 28pt from the right is
            // inside that style's 32pt gutter, outside the compact 24pt gutter.
            let side = top.withOffset(CGVector(dx: right ? -28 : 18, dy: 0))
            side.press(forDuration: 0.05, thenDragTo: side.withOffset(CGVector(dx: 1, dy: 55)))
            XCTAssertTrue(visible.exists, "A short gutter drag must not dismiss")
            side.press(forDuration: 0.05, thenDragTo: side.withOffset(CGVector(dx: right ? -24 : 24, dy: 172)))
            XCTAssertTrue(open.waitForExistence(timeout: 5), "Start in the side gutter, end over the lyrics")
            let count = app.staticTexts["smoke.interaction.player-close-count"]
            expectation(for: NSPredicate(format: "label == %@", "Closed: \(3 + index)"), evaluatedWith: count)
            waitForExpectations(timeout: 5)
            XCTAssertEqual(app.staticTexts["smoke.interaction.player-binding"].label, "Player binding: false")
            XCTAssertEqual(app.staticTexts["smoke.interaction.audio-state"].label, "Playing; starts=1")
            if !right { open.tap(); XCTAssertTrue(visible.waitForExistence(timeout: 5)) }
        }
        record("both lyric gutters return to the library with the same audio still playing", app: app)

        // A control from the exact same x inside a long lyric must actually
        // move the scroll content. A player that just ignores all drags fails.
        open.tap()
        XCTAssertTrue(visible.waitForExistence(timeout: 5))
        let moveUp = lyrics.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.86))
        moveUp.press(forDuration: 0.05, thenDragTo: moveUp.withOffset(CGVector(dx: 0, dy: -117)),
                     withVelocity: .slow, thenHoldForDuration: 0.25)
        let thirdText = lyricText(3)
        let leftX = insetX(right: false)
        assertLongTextContains(leftX, thirdText)
        let beforeY = firstTextLineY(thirdText)
        XCTAssertTrue(lyrics.frame.insetBy(dx: 0, dy: 2).contains(CGPoint(x: leftX, y: beforeY)))
        let fromLong = point(leftX, beforeY)
        fromLong.press(forDuration: 0.05, thenDragTo: fromLong.withOffset(CGVector(dx: 0, dy: 180)),
                       withVelocity: .slow, thenHoldForDuration: 0.25)
        XCTAssertTrue(visible.exists, "A start on long text scrolls at the short lyric's left-side x")
        XCTAssertGreaterThan(firstTextLineY(thirdText) - beforeY, 24, "The actual lyric moved down")

        // The short intrinsic Text is a separate accessibility element from
        // its full-width tappable row. Check the two starts against the actual
        // short text bounds without consulting the implementation's classifier.
        for (index, right) in [false, true].enumerated() {
            if right { open.tap(); XCTAssertTrue(visible.waitForExistence(timeout: 5)) }
            let text = lyricText(2)
            XCTAssertTrue(text.waitForExistence(timeout: 5))
            let x = insetX(right: right)
            let rect = text.frame
            XCTAssertGreaterThan(right ? x - rect.maxX : rect.minX - x, 8, "Start is genuinely beside this short line")
            XCTAssertGreaterThan(min(x - lyrics.frame.minX, lyrics.frame.maxX - x), 32, "Start is outside both fixed gutters")
            XCTAssertTrue(lyrics.frame.contains(CGPoint(x: x, y: rect.midY)))
            let down = max(185, 2 * abs(rect.midX - x) + 15)
            let start = point(x, rect.midY)
            start.press(forDuration: 0.05, thenDragTo: point(rect.midX, rect.midY + down))
            XCTAssertTrue(open.waitForExistence(timeout: 5), "Start beside the short lyric, move toward the text, and return")
            let closed = app.staticTexts["smoke.interaction.player-close-count"]
            expectation(for: NSPredicate(format: "label == %@", "Closed: \(5 + index)"), evaluatedWith: closed)
            waitForExpectations(timeout: 5)
            XCTAssertEqual(app.staticTexts["smoke.interaction.player-binding"].label, "Player binding: false")
            XCTAssertEqual(app.staticTexts["smoke.interaction.audio-state"].label, "Playing; starts=1")
        }
        record("inside both short-line margins returns; identical x on long text scrolls; audio keeps playing", app: app)
    }
}
