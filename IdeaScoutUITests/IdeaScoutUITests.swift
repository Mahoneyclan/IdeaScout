// IdeaScoutUITests.swift
// Automated screen tests for the critical flows: first launch with consent, a refresh, the paywall
// after the trial, and "Delete all my data". The app runs in its sealed test mode (TestMode.swift):
// in-memory database, separate settings and Keychain, fake sources and a scripted AI. So these tests
// never touch the owner's real data, never use the network and never spend money.

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

    private func button(_ app: XCUIApplication, startingWith text: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", text)).firstMatch
    }

    /// First launch: welcome pages, then the consent screen before any data goes to a cloud AI.
    func testWelcomeAsksForConsentThenOpensTheApp() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Welcome to IdeaScout"].waitForExistence(timeout: 10))
        app.buttons["Continue"].tap()
        XCTAssertTrue(app.staticTexts["Free for 7 days"].waitForExistence(timeout: 5))
        app.buttons["Continue"].tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["Agree"].waitForExistence(timeout: 5), "consent screen should appear")
        XCTAssertTrue(element(app, containing: "confidential").exists, "confidential-data warning should show")
        app.buttons["Agree"].tap()
        XCTAssertTrue(app.navigationBars["Ideas"].waitForExistence(timeout: 10))
    }

    /// The main action: the automatic refresh at launch shows the day's idea, and a second refresh the
    /// same day asks first (it costs money).
    func testRefreshShowsIdeasAndASecondRefreshAsksFirst() {
        let app = launch("-ui-skip-welcome")
        XCTAssertTrue(element(app, containing: "InvoiceChaser").waitForExistence(timeout: 20))
        let again = button(app, startingWith: "Refresh again")
        XCTAssertTrue(again.waitForExistence(timeout: 5))
        again.tap()
        XCTAssertTrue(element(app, containing: "Run another refresh today?").waitForExistence(timeout: 5))
    }

    /// After the trial, refreshing leads to the paywall; unlocking restores the refresh button.
    func testExpiredTrialShowsPaywallAndUnlockWorks() {
        let app = launch("-ui-skip-welcome", "-ui-trial-expired")
        let unlock = button(app, startingWith: "Unlock to find new ideas")
        XCTAssertTrue(unlock.waitForExistence(timeout: 10))
        unlock.tap()
        XCTAssertTrue(app.staticTexts["Your free trial has ended"].waitForExistence(timeout: 5))
        button(app, startingWith: "Unlock forever").tap()
        XCTAssertTrue(button(app, startingWith: "Find today's ideas").waitForExistence(timeout: 10))
    }

    /// "Delete all my data" asks first, then returns to the welcome screens.
    func testDeleteAllMyDataReturnsToWelcome() {
        let app = launch("-ui-skip-welcome")
        app.tabBars.buttons["Settings"].tap()
        let about = element(app, containing: "About & privacy")
        for _ in 0..<6 where !about.isHittable { app.swipeUp() }
        about.tap()
        let delete = app.buttons["Delete all my data"]
        for _ in 0..<5 where !delete.isHittable { app.swipeUp() }
        delete.tap()
        let confirm = app.buttons["Delete everything"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "should ask before deleting")
        confirm.tap()
        XCTAssertTrue(app.staticTexts["Welcome to IdeaScout"].waitForExistence(timeout: 10))
    }
}
