import XCTest
import SwiftUI
import TOMLDecoder
@testable import durian_lib

final class ProfileTests: XCTestCase {

    // MARK: - Test TOML

    private let profilesTOML = """
    [[profile]]
    name = "All"
    accounts = ["*"]
    default = true
    color = "#3B82F6"

    [[profile]]
    name = "Personal"
    accounts = ["personal"]
    color = "#10B981"

    [[profile]]
    name = "Work"
    accounts = ["work", "company"]
    color = "#F59E0B"

    [[profile.folders]]
    name = "Inbox"
    icon = "tray"
    query = "tag:inbox"

    [[profile.folders]]
    name = "Priority"
    icon = "star"
    query = "tag:flagged AND tag:inbox"
    """

    // MARK: - Helpers

    private static let testDefaultFolders: [FolderConfig] = [
        FolderConfig(name: "Inbox", icon: "tray", query: "tag:inbox")
    ]

    private func makeAllProfile() -> Profile {
        Profile(name: "All", accounts: ["*"], isDefault: true, color: nil, folders: Self.testDefaultFolders)
    }

    private func makeAccountProfile(accounts: [String]) -> Profile {
        Profile(name: "Work", accounts: accounts, isDefault: false, color: "#F59E0B", folders: Self.testDefaultFolders)
    }

    // MARK: - TOML Decoding

    func testDecodeProfiles() throws {
        let config = try TOMLDecoder().decode(ProfilesConfig.self, from: profilesTOML)

        XCTAssertEqual(config.profile.count, 3)
        XCTAssertEqual(config.profile[0].name, "All")
        XCTAssertEqual(config.profile[0].accounts, ["*"])
        XCTAssertEqual(config.profile[0].default, true)
        XCTAssertEqual(config.profile[1].name, "Personal")
        XCTAssertEqual(config.profile[1].accounts, ["personal"])
        XCTAssertEqual(config.profile[2].name, "Work")
        XCTAssertEqual(config.profile[2].accounts, ["work", "company"])
    }

    func testProfileColors() throws {
        let config = try TOMLDecoder().decode(ProfilesConfig.self, from: profilesTOML)
        XCTAssertEqual(config.profile[0].color, "#3B82F6")
        XCTAssertEqual(config.profile[1].color, "#10B981")
    }

    func testProfileFolders() throws {
        let config = try TOMLDecoder().decode(ProfilesConfig.self, from: profilesTOML)

        // Work profile has custom folders
        let workFolders = config.profile[2].folders
        XCTAssertNotNil(workFolders)
        XCTAssertEqual(workFolders?.count, 2)
        XCTAssertEqual(workFolders?[0].name, "Inbox")
        XCTAssertEqual(workFolders?[1].name, "Priority")
        XCTAssertEqual(workFolders?[1].query, "tag:flagged AND tag:inbox")
    }

    // MARK: - Query Building

    @MainActor
    func testBuildQueryAllProfile() {
        let profile = makeAllProfile()
        let manager = ProfileManager(profiles: [profile], currentProfile: profile)

        let query = manager.buildQuery(folderName: "Inbox")
        XCTAssertEqual(query, "tag:inbox")
    }

    @MainActor
    func testBuildQueryAccountProfile() {
        let profile = makeAccountProfile(accounts: ["work"])
        let manager = ProfileManager(profiles: [profile], currentProfile: profile)

        let query = manager.buildQuery(folderName: "Inbox")
        XCTAssertEqual(query, "(tag:inbox) AND (path:work/**)")
    }

    @MainActor
    func testBuildQueryMultipleAccounts() {
        let profile = makeAccountProfile(accounts: ["work", "company"])
        let manager = ProfileManager(profiles: [profile], currentProfile: profile)

        let query = manager.buildQuery(folderName: "Inbox")
        XCTAssertEqual(query, "(tag:inbox) AND (path:work/** OR path:company/**)")
    }

    @MainActor
    func testApplyProfileFilterAllProfile() {
        let profile = makeAllProfile()
        let manager = ProfileManager(profiles: [profile], currentProfile: profile)

        let filtered = manager.applyProfileFilter(to: "from:alice@example.com")
        XCTAssertEqual(filtered, "from:alice@example.com")
    }

    @MainActor
    func testApplyProfileFilterAccountProfile() {
        let profile = makeAccountProfile(accounts: ["work"])
        let manager = ProfileManager(profiles: [profile], currentProfile: profile)

        let filtered = manager.applyProfileFilter(to: "from:alice@example.com")
        XCTAssertEqual(filtered, "(from:alice@example.com) AND (path:work/**)")
    }

    @MainActor
    func testBuildQueryFallbackTag() {
        let profile = makeAllProfile()
        let manager = ProfileManager(profiles: [profile], currentProfile: profile)

        let query = manager.buildQuery(folderName: "Sent")
        XCTAssertEqual(query, "tag:sent")
    }

    // MARK: - Color(hex:)

    func testColorHexRed() {
        let color = Color(hex: "#FF0000")
        XCTAssertNotNil(color)
    }

    func testColorHexWithoutHash() {
        let color = Color(hex: "00FF00")
        XCTAssertNotNil(color)
    }

    func testColorHexInvalidFallback() {
        let color = Color(hex: "XYZ")
        XCTAssertNotNil(color)
    }

    // MARK: - Profile.isAll

    func testProfileIsAll() {
        let profile = makeAllProfile()
        XCTAssertTrue(profile.isAll)
    }

    func testProfileIsNotAll() {
        let profile = makeAccountProfile(accounts: ["work"])
        XCTAssertFalse(profile.isAll)
    }
}
