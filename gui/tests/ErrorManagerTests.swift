import XCTest
@testable import durian_lib

@MainActor
final class ErrorManagerTests: XCTestCase {

    /// Create a manager with startup suppression already elapsed
    private func makeManager() -> ErrorManager {
        ErrorManager(startupTime: Date.distantPast)
    }

    func testShowCriticalSetsCurrentError() async {
        let manager = makeManager()
        let error = UserFacingError(title: "Fail", message: "Something broke", severity: .critical)
        manager.show(error)

        // show() uses Task with 300ms delay
        try? await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertNotNil(manager.currentError)
        XCTAssertEqual(manager.currentError?.title, "Fail")
        XCTAssertEqual(manager.currentError?.severity, .critical)
    }

    func testShowWarningSetsCurrentError() async {
        let manager = makeManager()
        let error = UserFacingError(title: "Warn", message: "Heads up", severity: .warning)
        manager.show(error)

        try? await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertNotNil(manager.currentError)
        XCTAssertEqual(manager.currentError?.title, "Warn")
    }

    func testDismissClearsError() async {
        let manager = makeManager()
        let error = UserFacingError(title: "Error", message: "msg", severity: .critical)
        manager.show(error)

        try? await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertNotNil(manager.currentError)

        manager.dismiss()
        XCTAssertNil(manager.currentError)
    }

    func testSecondShowReplacesFirst() async {
        let manager = makeManager()
        let first = UserFacingError(title: "First", message: "1", severity: .critical)
        let second = UserFacingError(title: "Second", message: "2", severity: .critical)

        manager.show(first)
        try? await Task.sleep(nanoseconds: 400_000_000)
        manager.show(second)
        try? await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertEqual(manager.currentError?.title, "Second")
    }

    func testShowWarningConvenience() async {
        let manager = makeManager()
        manager.showWarning(title: "Net", message: "Offline")

        try? await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertNotNil(manager.currentError)
        XCTAssertEqual(manager.currentError?.severity, .warning)
    }

    func testShowCriticalConvenience() async {
        let manager = makeManager()
        manager.showCritical(title: "Fatal", message: "Crash")

        try? await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertNotNil(manager.currentError)
        XCTAssertEqual(manager.currentError?.severity, .critical)
    }

    func testStartupSuppression() async {
        // Fresh manager — warnings within 4s should be suppressed
        let manager = ErrorManager()
        manager.showWarning(title: "Suppressed", message: "Should not appear")

        try? await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertNil(manager.currentError)
    }
}
