//
//  MANTAUITests.swift
//  MANTAUITests
//
//  Created by Molfese, Peter  [E] on 7/10/26.
//

import XCTest

final class MANTAUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    private func startUnlabeledSession(_ app: XCUIApplication) {
        let start = app.buttons["startNewSession"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        XCTAssertTrue(start.isEnabled)
        XCTAssertTrue(app.buttons["openExistingSession"].exists)
        XCTAssertFalse(app.textFields["sessionNameField"].exists)
        start.tap()
        XCTAssertTrue(start.waitForNonExistence(timeout: 5))
    }

    @MainActor
    private func openCurrentSession(_ app: XCUIApplication) {
        let open = app.buttons["openExistingSession"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        open.tap()
        let current = app.buttons["openCurrentSession"]
        XCTAssertTrue(current.waitForExistence(timeout: 5))
        current.tap()
        XCTAssertTrue(current.waitForNonExistence(timeout: 5))
    }

    @MainActor
    func testUnlabeledSessionSurvivesRelaunch() throws {
        let app = XCUIApplication()
        app.launch()
        startUnlabeledSession(app)
        app.terminate()
        app.launch()
        openCurrentSession(app)
        XCTAssertTrue(app.buttons["pauseResumeCapture"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testHoldMenuCancelsThenEndsSession() throws {
        let app = XCUIApplication()
        app.launch()
        startUnlabeledSession(app)
        let control = app.buttons["pauseResumeCapture"]
        XCTAssertTrue(control.waitForExistence(timeout: 5))
        control.press(forDuration: 1)
        let finish = app.buttons["saveAndEndSession"]
        XCTAssertTrue(finish.waitForExistence(timeout: 5))
        // Capture the menu action's location to exercise a continuous hold/slide
        // on the next opening, rather than a separate tap-to-select.
        let target = finish.frame
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
        XCTAssertTrue(finish.waitForNonExistence(timeout: 5))
        XCTAssertTrue(control.isEnabled)
        XCTAssertFalse(app.alerts["Session ended"].exists)
        let endPoint = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: target.midX, dy: target.midY))
        control.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 1, thenDragTo: endPoint)
        XCTAssertTrue(app.alerts["Session ended"].waitForExistence(timeout: 20))
        app.alerts["Session ended"].buttons["OK"].tap()
        XCTAssertFalse(control.isEnabled)
        app.terminate()
        app.launch()
        openCurrentSession(app)
        XCTAssertTrue(control.waitForExistence(timeout: 5))
        XCTAssertFalse(control.isEnabled)
    }

    @MainActor
    func testTopRouteNavigationAndSplitView() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launch()
        startUnlabeledSession(app)
        let photos = app.buttons["captureRoute-photos"]
        XCTAssertTrue(photos.waitForExistence(timeout: 10))
        XCTAssertFalse(app.segmentedControls["Capture view"].exists)
        XCTAssertTrue(app.buttons["captureHighResolutionStill"].exists)
        photos.tap()
        XCTAssertTrue(app.buttons["captureRoute-reference"].label.contains("skipped"))
        let finish = app.buttons["captureRoute-finish"]
        finish.tap()
        XCTAssertTrue(app.buttons["captureRouteFinish"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.alerts["Session ended"].exists)
        app.buttons["captureRoute-reference"].tap()
        let expand = app.buttons["captureExpand-Camera"]
        XCTAssertTrue(expand.exists)
        expand.tap()
        XCTAssertEqual(expand.label, "Restore split view")
        expand.tap()
        XCTAssertTrue(app.buttons["captureExpand-Head Model"].exists)
        XCTAssertGreaterThan(app.frame.width, app.frame.height)
        XCTAssertTrue(app.buttons["captureRoute-setup"].isHittable)
        XCTAssertTrue(app.buttons["captureRoute-finish"].isHittable)
        let left = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        left.name = "Top route landscape left"
        left.lifetime = .keepAlways
        add(left)
        XCUIDevice.shared.orientation = .landscapeRight
        XCTAssertTrue(photos.waitForExistence(timeout: 5))
        app.buttons["captureRoute-reference"].tap()
        XCTAssertTrue(app.buttons["captureRoute-finish"].isHittable)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Top route landscape right"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        XCUIDevice.shared.orientation = .portrait
        XCTAssertGreaterThan(app.frame.width, app.frame.height, "iPad capture must remain landscape")
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
