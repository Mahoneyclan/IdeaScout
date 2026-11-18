// IdeaScoutUITests.swift
// The few screen tests run before a release (owner, 16 Nov 2026: unit tests cover the logic; screens are checked
// by hand from the release list): first launch with consent, the main action (a refresh, the idea with its
// principles and price cap, and a second refresh asking first), and "Delete all my data". The app runs in its sealed
// test mode (TestMode.swift): in-memory database, separate settings and Keychain, fake sources and a scripted AI.
// So these tests never touch the owner's real data, never use the network and never spend money.

import XCTest

final class IdeaScoutUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    /// Launches the app in test mode with extra arguments.
    private func launch(_ arguments: String...) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"] + arguments
        app.launch()
        return app
    }

    /// Any element whose label contains `text` (SwiftUI merges a NavigationLink's texts into one button label).
    private func element(_ app: XCUIApplication, containing text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// A tab: in the tab bar on iPhone; on iPad the tabs sit at the top (or in the sidebar) as plain buttons.
    private func tab(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        let inTabBar = app.tabBars.buttons[name]
        return inTabBar.exists ? inTabBar : app.buttons[name].firstMatch
    }

    private func button(_ app: XCUIApplication, startingWith text: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", text)).firstMatch
    }


    /// First launch: welcome pages (including the user's area and tool, and guided key setup), then the consent screen
    /// before any data goes to a cloud AI.
    func testWelcomeAsksForConsentThenOpensTheApp() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Welcome to IdeaScout"].waitForExistence(timeout: 10))
        app.buttons["Continue"].tap()
        XCTAssertTrue(app.navigationBars["About you"].waitForExistence(timeout: 5), "should ask about the user's area and tool")
        app.buttons["Continue"].tap()
        XCTAssertTrue(element(app, containing: "Paste it here").waitForExistence(timeout: 5), "key setup should be guided")
        app.buttons["Done"].tap()
        let anyway = app.buttons["Continue anyway"]
        if anyway.waitForExistence(timeout: 3) { anyway.tap() }   // no key saved in test mode: it says what that means
        XCTAssertTrue(app.buttons["Agree"].waitForExistence(timeout: 5), "consent screen should appear")
        XCTAssertTrue(element(app, containing: "confidential").exists, "confidential-data warning should show")
        app.buttons["Agree"].tap()
        XCTAssertTrue(app.navigationBars["Ideas"].waitForExistence(timeout: 10))
    }

    /// The main action: the automatic refresh at launch shows the day's idea; its screen lists the principles, the
    /// competitor and how the price compares with the 25% cap; refreshing asks first in a pop-up (it costs money).
    func testRefreshShowsTheIdeaAndASecondRefreshAsksFirst() {
        let app = launch("-ui-skip-welcome")
        let idea = element(app, containing: "NudgeBill")
        XCTAssertTrue(idea.waitForExistence(timeout: 20))
        XCTAssertTrue(element(app, containing: "Undercuts DunningDesk").exists, "the card should say which competitor it undercuts")
        idea.tap()
        let payback = element(app, containing: "Sales cover the build cost")
        for _ in 0..<5 where !payback.exists { app.swipeUp() }
        XCTAssertTrue(payback.exists, "the principles should be listed")
        let cap = element(app, containing: "the cap is 25%")
        for _ in 0..<3 where !cap.exists { app.swipeUp() }
        XCTAssertTrue(cap.exists, "the price should be compared with the 25% cap")
        app.navigationBars.buttons.firstMatch.tap()
        // Pulling down and the ↻ button open the same pop-up; the button is the reliable one to tap in a test.
        let refresh = app.navigationBars["Ideas"].buttons["Refresh"]
        XCTAssertTrue(refresh.waitForExistence(timeout: 5))
        refresh.tap()
        XCTAssertTrue(element(app, containing: "Run another refresh today?").waitForExistence(timeout: 5), "a refresh asks first")
        app.alerts.buttons["Cancel"].tap()
    }

    /// "Delete all my data" asks first, then returns to the welcome screens.
    func testDeleteAllMyDataReturnsToWelcome() {
        let app = launch("-ui-skip-welcome")
        tab(app, "Settings").tap()
        let about = element(app, containing: "About & privacy")
        for _ in 0..<6 where !about.isHittable { app.swipeUp() }
        about.tap()
        XCTAssertTrue(app.navigationBars["About"].waitForExistence(timeout: 5), "About screen should open")
        let delete = app.buttons["Delete all my data"]
        for _ in 0..<8 where !(delete.exists && delete.isHittable) { app.swipeUp() }
        delete.tap()
        let confirm = app.buttons["Delete everything"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "should ask before deleting")
        confirm.tap()
        XCTAssertTrue(app.staticTexts["Welcome to IdeaScout"].waitForExistence(timeout: 10))
    }
}
