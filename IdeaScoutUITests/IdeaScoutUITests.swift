// IdeaScoutUITests.swift
// Automated screen tests for the critical flows: first launch with consent, a refresh, the paywall
// after the trial, "Delete all my data", saving an idea, making a starter kit, and iPad rotation. The app runs in its sealed test mode (TestMode.swift):
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

    /// A tab: in the tab bar on iPhone; on iPad the tabs sit at the top (or in the sidebar) as plain buttons.
    private func tab(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        let inTabBar = app.tabBars.buttons[name]
        return inTabBar.exists ? inTabBar : app.buttons[name].firstMatch
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

    /// iPad only: the main screen keeps working in landscape and back in portrait (iPhone stays portrait).
    func testIPadRotationKeepsTheMainScreenWorking() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPhone is portrait-only")
        let app = launch("-ui-skip-welcome")
        XCTAssertTrue(element(app, containing: "InvoiceChaser").waitForExistence(timeout: 20))
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(button(app, startingWith: "Refresh again").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, containing: "InvoiceChaser").isHittable, "the idea should still be on screen in landscape")
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(button(app, startingWith: "Refresh again").waitForExistence(timeout: 5))
    }

    /// Saving an idea from its detail screen puts it in Saved; unsaving it there shows the empty state.
    func testSavedIdeaAppearsInSavedAndCanBeUnsaved() {
        let app = launch("-ui-skip-welcome")
        let idea = element(app, containing: "InvoiceChaser")
        XCTAssertTrue(idea.waitForExistence(timeout: 20))
        idea.tap()
        let save = app.buttons["Save idea"]
        XCTAssertTrue(save.waitForExistence(timeout: 5), "detail screen should offer Save")
        save.tap()
        XCTAssertTrue(app.buttons["Remove from Saved"].waitForExistence(timeout: 5))
        tab(app, "Saved").tap()
        let saved = element(app, containing: "InvoiceChaser")
        XCTAssertTrue(saved.waitForExistence(timeout: 5), "the idea should be listed in Saved")
        saved.swipeLeft()
        let unsave = app.buttons["Unsave"]
        XCTAssertTrue(unsave.waitForExistence(timeout: 5))
        unsave.tap()
        XCTAssertTrue(app.staticTexts["Nothing saved yet"].waitForExistence(timeout: 5))
    }

    /// The idea's main action: make a starter kit, pick a coding tool and see the share button worded for it.
    func testStarterKitIsMadeAndWordedForTheChosenTool() {
        let app = launch("-ui-skip-welcome")
        let idea = element(app, containing: "InvoiceChaser")
        XCTAssertTrue(idea.waitForExistence(timeout: 20))
        idea.tap()
        let kit = button(app, startingWith: "Starter kit")
        XCTAssertTrue(kit.waitForExistence(timeout: 5), "detail screen should offer the starter kit")
        kit.tap()
        let make = button(app, startingWith: "Make starter kit")
        XCTAssertTrue(make.waitForExistence(timeout: 5))
        make.tap()
        XCTAssertTrue(button(app, startingWith: "Share for Claude Code").waitForExistence(timeout: 10), "kit should be made")
        button(app, startingWith: "Cursor").tap()
        XCTAssertTrue(button(app, startingWith: "Share for Cursor").waitForExistence(timeout: 5))
    }

    func testIdeaIsImprovedAndTheVersionKept() {
        let app = launch("-ui-skip-welcome")
        let idea = element(app, containing: "InvoiceChaser")
        XCTAssertTrue(idea.waitForExistence(timeout: 20))
        idea.tap()
        let improve = button(app, startingWith: "Improve this idea")
        for _ in 0..<4 where !improve.isHittable { app.swipeUp() }
        improve.tap()
        let start = button(app, startingWith: "Improve this idea")
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()
        XCTAssertTrue(element(app, containing: "Round 1").waitForExistence(timeout: 10), "a round should finish")
        let keep = button(app, startingWith: "Keep this version")
        for _ in 0..<4 where !keep.exists { app.swipeUp() }
        XCTAssertTrue(keep.exists)
        keep.tap()
        let undo = button(app, startingWith: "Undo improvement")
        for _ in 0..<4 where !undo.exists { app.swipeDown() }
        XCTAssertTrue(undo.exists, "keeping a version should offer undo")
    }
}
