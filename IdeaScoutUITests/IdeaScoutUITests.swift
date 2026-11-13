// IdeaScoutUITests.swift
// Automated screen tests for the critical flows: first launch with consent, a refresh, the paywall
// after the trial, "Delete all my data", saving an idea, making a starter kit, "Undercut an app" reading a link,
// and iPad rotation. The app runs in its sealed test mode (TestMode.swift):
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

    /// "Undercut an app" opens from the Ideas tab and reads the app's name from a pasted App Store link, without
    /// any AI call (the test stops before the paid button).
    func testUndercutReadsTheAppFromALink() {
        let app = launch("-ui-skip-welcome")
        let open = app.buttons["Undercut an app"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 20))
        open.tap()
        let field = app.textFields["App Store link or app name"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("https://apps.apple.com/au/app/things-3/id904237743")
        XCTAssertTrue(element(app, containing: "App Store id904237743").waitForExistence(timeout: 5), "the link should be read")
        XCTAssertEqual(app.textFields["App name, read from the link"].firstMatch.value as? String, "Things 3")
        XCTAssertTrue(button(app, startingWith: "Find a cheaper idea").exists)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Ideas"].waitForExistence(timeout: 5))
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

    /// Settings is a short list: a text setting opens its own screen, and its row then shows the value.
    func testSettingsRowOpensItsScreenAndShowsTheValue() {
        let app = launch("-ui-skip-welcome")
        tab(app, "Settings").tap()
        let row = element(app, containing: "Interest area")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, containing: "Any area").exists, "blank shows as any area")
        row.tap()
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Fitness coaching")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(element(app, containing: "Fitness coaching").waitForExistence(timeout: 5))
        let shot = XCTAttachment(screenshot: app.screenshot())   // kept, to review the layout
        shot.name = "Settings"
        shot.lifetime = .keepAlways
        add(shot)
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
        XCTAssertTrue(button(app, startingWith: "Share build prompt for Claude Code").waitForExistence(timeout: 10), "kit should be made")
    }

    func testIdeaIsImprovedAndTheVersionKept() {
        let app = launch("-ui-skip-welcome")
        let idea = element(app, containing: "InvoiceChaser")
        XCTAssertTrue(idea.waitForExistence(timeout: 20))
        idea.tap()
        let improve = button(app, startingWith: "Improve this idea")
        for _ in 0..<4 where !improve.isHittable { app.swipeUp() }
        improve.tap()
        // The idea screen's link and the Improve screen's start button share a name: wait for the Improve screen.
        XCTAssertTrue(element(app, containing: "Each round, the AI rewrites").waitForExistence(timeout: 5))
        let start = button(app, startingWith: "Improve this idea")
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()
        XCTAssertTrue(button(app, startingWith: "Improve again").waitForExistence(timeout: 10), "the run should finish")
        if UIDevice.current.userInterfaceIdiom == .pad {
            let compare = element(app, containing: "Original and round side by side")
            for _ in 0..<4 where !compare.exists { app.swipeUp() }
            XCTAssertTrue(compare.exists, "iPad should compare side by side")
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "iPad comparison"; shot.lifetime = .keepAlways
            add(shot)
        }
        let round = element(app, containing: "Round 1")
        for _ in 0..<4 where !round.exists { app.swipeUp() }
        XCTAssertTrue(round.exists, "a round should be listed")
        let keep = button(app, startingWith: "Keep this version")
        for _ in 0..<4 where !keep.exists { app.swipeUp() }
        XCTAssertTrue(keep.exists)
        keep.tap()
        let kept = element(app, containing: "Kept round 1")
        for _ in 0..<4 where !kept.exists { app.swipeDown() }
        XCTAssertTrue(kept.exists, "keeping a version should say so")
        let undo = button(app, startingWith: "Undo improvement")
        for _ in 0..<4 where !undo.exists { app.swipeDown() }
        XCTAssertTrue(undo.exists, "keeping a version should offer undo")
    }

    /// Ideas are judged on the five principles: the idea screen lists them, with the competitor and price.
    func testIdeaShowsTheFivePrinciples() {
        let app = launch("-ui-skip-welcome")
        let idea = element(app, containing: "InvoiceChaser")
        XCTAssertTrue(idea.waitForExistence(timeout: 20))
        XCTAssertTrue(element(app, containing: "Undercuts Chaser").exists, "the card should say which competitor it undercuts")
        idea.tap()
        let cheaper = element(app, containing: "Materially cheaper")
        for _ in 0..<5 where !cheaper.exists { app.swipeUp() }
        XCTAssertTrue(cheaper.exists, "the five principles should be listed")
        let competitor = element(app, containing: "Chaser")
        for _ in 0..<3 where !competitor.exists { app.swipeUp() }
        XCTAssertTrue(competitor.exists, "the competitor should be listed")
    }
}
