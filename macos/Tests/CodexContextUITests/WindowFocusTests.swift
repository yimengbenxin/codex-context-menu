import XCTest
import AppKit
@testable import CodexTokenOverlayMac

final class WindowFocusTests: XCTestCase {
    @MainActor
    func testInactiveReopenDoesNotCreateAWindow() {
        let application = NSApplication.shared
        XCTAssertFalse(application.isActive)
        let before = application.windows.count
        let delegate = AppDelegate()
        XCTAssertFalse(delegate.applicationShouldHandleReopen(application, hasVisibleWindows: false))
        XCTAssertEqual(application.windows.count, before)
        XCTAssertFalse(delegate.applicationShouldHandleReopen(application, hasVisibleWindows: true))
        XCTAssertEqual(application.windows.count, before)
    }

    @MainActor
    func testTargetResultDoesNotConstructOrActivateAWindow() {
        let application = NSApplication.shared
        let before = application.windows.count
        let controller = ContextSettingsController()
        controller.loadTarget(project: "/fixture-unavailable", threadID: nil, observedWindow: nil)
        XCTAssertEqual(application.windows.count, before)
        XCTAssertFalse(application.isActive)
        XCTAssertEqual(controller.model.page, .context)
    }

    @MainActor
    func testTargetResultCannotInterruptSaving() {
        let controller = ContextSettingsController()
        controller.model.saving = true
        controller.model.page = .usage
        controller.loadTarget(project: "/fixture-unavailable", threadID: nil, observedWindow: nil)
        XCTAssertEqual(controller.model.page, .usage)
        XCTAssertNil(controller.model.project)
    }
}
