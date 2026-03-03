import XCTest
import TOMLDecoder
@testable import durian_lib

final class ConfigTests: XCTestCase {

    // MARK: - Test TOML Strings

    private let fullConfigTOML = """
    [settings]
    notifications_enabled = true
    theme = "dark"
    load_remote_images = true

    [sync]
    mode = "bidirectional"
    gui_auto_sync = false
    auto_fetch_interval = 120
    full_sync_interval = 7200

    [signatures]
    default = "Best regards"
    work = "Kind regards,\\nTest User\\nAcme Corp."

    [[accounts]]
    name = "Personal"
    email = "alice@example.com"

    [[accounts]]
    name = "Work"
    email = "alice@company.com"
    default_signature = "work"
    """

    // MARK: - Full Config Decoding

    func testDecodeFullConfig() throws {
        let config = try TOMLDecoder().decode(AppConfig.self, from: fullConfigTOML)

        // Accounts
        XCTAssertEqual(config.accounts.count, 2)
        XCTAssertEqual(config.accounts[0].name, "Personal")
        XCTAssertEqual(config.accounts[0].email, "alice@example.com")
        XCTAssertNil(config.accounts[0].defaultSignature)
        XCTAssertEqual(config.accounts[1].name, "Work")
        XCTAssertEqual(config.accounts[1].email, "alice@company.com")
        XCTAssertEqual(config.accounts[1].defaultSignature, "work")

        // Settings
        XCTAssertEqual(config.settings.theme, "dark")
        XCTAssertTrue(config.settings.notificationsEnabled)
        XCTAssertTrue(config.settings.loadRemoteImages)

        // Sync
        XCTAssertEqual(config.sync.mode, "bidirectional")
        XCTAssertFalse(config.sync.guiAutoSync)
        XCTAssertEqual(config.sync.autoFetchInterval, 120.0)
        XCTAssertEqual(config.sync.fullSyncInterval, 7200)

        // Signatures
        XCTAssertEqual(config.signatures["default"], "Best regards")
        XCTAssertNotNil(config.signatures["work"])
    }

    // MARK: - Minimal Config (defaults)

    func testDecodeMinimalConfig() throws {
        let minimalTOML = "[settings]\n"
        let config = try TOMLDecoder().decode(AppConfig.self, from: minimalTOML)

        XCTAssertEqual(config.accounts.count, 0)
        XCTAssertEqual(config.settings.theme, "system")
        XCTAssertTrue(config.settings.notificationsEnabled)
        XCTAssertFalse(config.settings.loadRemoteImages)
        XCTAssertEqual(config.sync.mode, "bidirectional")
        XCTAssertTrue(config.sync.guiAutoSync)
        XCTAssertEqual(config.sync.autoFetchInterval, 60.0)
        XCTAssertTrue(config.signatures.isEmpty)
    }

    // MARK: - MailAccount

    func testMailAccountWithSignature() {
        let account = MailAccount(name: "Work", email: "w@co.com", defaultSignature: "formal")
        XCTAssertEqual(account.defaultSignature, "formal")
    }

    func testMailAccountWithoutSignature() {
        let account = MailAccount(name: "Personal", email: "me@me.com")
        XCTAssertNil(account.defaultSignature)
    }

    // MARK: - generateTOML round-trip

    func testGenerateTOMLRoundTrip() throws {
        let original = AppConfig(
            accounts: [
                MailAccount(name: "Test", email: "test@example.com", defaultSignature: "sig1"),
            ],
            settings: AppSettings(),
            sync: SyncSettings(),
            signatures: ["sig1": "Cheers"]
        )

        let manager = ConfigManager(config: original)
        let tomlString = manager.generateTOML(from: original)

        // Decode the generated TOML back
        let decoded = try TOMLDecoder().decode(AppConfig.self, from: tomlString)

        XCTAssertEqual(decoded.accounts.count, 1)
        XCTAssertEqual(decoded.accounts[0].name, "Test")
        XCTAssertEqual(decoded.accounts[0].email, "test@example.com")
        XCTAssertEqual(decoded.accounts[0].defaultSignature, "sig1")
        XCTAssertEqual(decoded.settings.theme, "system")
        XCTAssertEqual(decoded.signatures["sig1"], "Cheers")
    }

    // MARK: - generateTOML edge cases

    func testGenerateTOMLWithSpecialCharacters() throws {
        let original = AppConfig(accounts: [], signatures: [
            "html": "<b>Max Mustermann</b>\nCEO\nExample GmbH",
            "quotes": "\"Best regards\" - Max",
            "path": "C:\\Users\\Mustermann\\sig.html"
        ])

        let manager = ConfigManager(config: original)
        let toml = manager.generateTOML(from: original)
        let decoded = try TOMLDecoder().decode(AppConfig.self, from: toml)

        XCTAssertEqual(decoded.signatures["html"], original.signatures["html"])
        XCTAssertEqual(decoded.signatures["quotes"], original.signatures["quotes"])
        XCTAssertEqual(decoded.signatures["path"], original.signatures["path"])
    }
}
