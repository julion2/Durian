import XCTest
import SwiftUI
@testable import durian_lib

@MainActor
final class SyncManagerTests: XCTestCase {

    // MARK: - SyncState.color

    func testSyncStateIdleColor() {
        XCTAssertEqual(SyncState.idle.color, Color.secondary)
    }

    func testSyncStateSyncingColor() {
        XCTAssertEqual(SyncState.syncing.color, Color.blue)
    }

    func testSyncStateSuccessColor() {
        XCTAssertEqual(SyncState.success.color, Color.green)
    }

    func testSyncStateFailedColor() {
        XCTAssertEqual(SyncState.failed("err").color, Color.red)
    }

    // MARK: - SyncState.shouldNotify

    func testSyncStateShouldNotifyOnlyForFailed() {
        XCTAssertFalse(SyncState.idle.shouldNotify)
        XCTAssertFalse(SyncState.syncing.shouldNotify)
        XCTAssertFalse(SyncState.success.shouldNotify)
        XCTAssertTrue(SyncState.failed("error").shouldNotify)
    }

    // MARK: - SyncState.statusText

    func testSyncStateStatusText() {
        XCTAssertEqual(SyncState.idle.statusText, "")
        XCTAssertEqual(SyncState.syncing.statusText, "Syncing...")
        XCTAssertEqual(SyncState.success.statusText, "Synced")
        XCTAssertEqual(SyncState.failed("timeout").statusText, "Failed: timeout")
    }

    // MARK: - SyncState Equatable

    func testSyncStateEquality() {
        XCTAssertEqual(SyncState.idle, SyncState.idle)
        XCTAssertEqual(SyncState.syncing, SyncState.syncing)
        XCTAssertEqual(SyncState.success, SyncState.success)
        XCTAssertEqual(SyncState.failed("a"), SyncState.failed("a"))
        XCTAssertNotEqual(SyncState.failed("a"), SyncState.failed("b"))
        XCTAssertNotEqual(SyncState.idle, SyncState.syncing)
    }
}
