// ScreenshotTests.swift
// Takes the App Store screenshots (owner, 17 Nov 2026) in sealed test mode with made-up sample data: the Ideas list,
// an idea's "Why it's a killer idea", a refresh in progress, Reimagine an app, the starter kit, and Support. It runs
// only when asked (environment IDEASCOUT_SCREENSHOTS=1, passed as TEST_RUNNER_IDEASCOUT_SCREENSHOTS=1 to xcodebuild),
// so normal test runs skip it. Each screenshot is attached to the test result, named for its order.

import XCTest

final class ScreenshotTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["IDEASCOUT_SCREENSHOTS"] == "1", "screenshots only on request")
        continueAfterFailure = false
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func element(_ app: XCUIApplication, containing text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    private func button(_ app: XCUIApplication, startingWith text: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", text)).firstMatch
    }

    private func tab(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        let inTabBar = app.tabBars.buttons[name]
        return inTabBar.exists ? inTabBar : app.buttons[name].firstMatch
    }

    func testAppStoreScreenshots() {
        // Portrait on both: Apple accepts portrait 13" iPad screenshots, and captures taken in landscape come out sideways.
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        // US English, so prices read "$40" rather than "USD 40".
        app.launchArguments = ["-ui-testing", "-ui-skip-welcome", "-ui-screenshots", "-AppleLanguages", "(en-US)", "-AppleLocale", "en_US"]
        app.launch()

        // 1. The Ideas list, after the launch refresh.
        let idea = element(app, containing: "NudgeBill")
        XCTAssertTrue(idea.waitForExistence(timeout: 40))
        sleep(2)
        shot(app, "1-ideas")

        // 2. Why it's a killer idea.
        idea.tap()
        XCTAssertTrue(element(app, containing: "Why it's a killer idea").waitForExistence(timeout: 10))
        sleep(1)
        shot(app, "2-idea")

        // 5 (taken now, shown later). The starter kit, made by the scripted AI.
        button(app, startingWith: "Starter kit").tap()
        let make = button(app, startingWith: "Make starter kit")
        XCTAssertTrue(make.waitForExistence(timeout: 10))
        make.tap()
        XCTAssertTrue(button(app, startingWith: "Copy prompt").waitForExistence(timeout: 20))
        sleep(1)
        shot(app, "5-starter-kit")
        // Back to the Ideas list by restarting (the back button differs between iPhone and iPad layouts).
        app.terminate()
        app.launch()
        XCTAssertTrue(element(app, containing: "NudgeBill").waitForExistence(timeout: 40))

        // 4. Reimagine an app: explained, with a way to reimagine it chosen.
        // Opened from "Recent apps" (test mode saves a sample run), so no typing is needed.
        app.buttons["Reimagine an app"].firstMatch.tap()
        let recent = element(app, containing: "TaskTidy")
        XCTAssertTrue(recent.waitForExistence(timeout: 10))
        recent.tap()
        let direction = element(app, containing: "Share a weekly chore rota")
        for _ in 0..<6 where !direction.exists { app.swipeUp() }   // the list loads rows as they scroll in
        XCTAssertTrue(direction.waitForExistence(timeout: 10))
        direction.tap()
        sleep(1)
        shot(app, "4-reimagine")
        app.buttons["Close"].firstMatch.tap()

        // 3. A refresh in progress, step by step (test mode pauses at the devil's advocate).
        app.navigationBars["Ideas"].buttons["Refresh"].tap()
        let refresh = app.alerts.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Refresh'")).firstMatch
        XCTAssertTrue(refresh.waitForExistence(timeout: 5))
        refresh.tap()
        XCTAssertTrue(element(app, containing: "Testing each idea").waitForExistence(timeout: 20))
        element(app, containing: "Come up with ideas").tap()   // open step 3 to show the draft ideas
        sleep(1)
        shot(app, "3-refresh")

        // 6. Support IdeaScout, at the bottom of Settings.
        tab(app, "Settings").tap()
        let support = element(app, containing: "Small coffee")
        for _ in 0..<8 where !support.isHittable { app.swipeUp() }
        XCTAssertTrue(support.exists)
        sleep(1)
        shot(app, "6-support")
    }
}
