import XCTest
@testable import OpenAIQuotaBar

final class SettingsTests: XCTestCase {
    @MainActor func testRenamePersistsOnlyNameAndKeepsAllFiveConnections() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("quotabar-rename-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("accounts.json")
        var original = Account.samples
        for index in original.indices { original[index].authSessionID = UUID() }
        try JSONEncoder().encode(original).write(to: file)
        let store = Store(accountsFile: file, makeClient: { _ in XCTFail("Renaming must not start authentication"); throw CancellationError() })
        store.selectedID = original[3].id
        try store.renameAccount(original[2].id, to: "  Daily work  ")
        var expected = original
        expected[2].name = "Daily work"
        XCTAssertEqual(store.accounts, expected)
        XCTAssertEqual(store.selectedID, original[3].id)
        XCTAssertEqual(Store(accountsFile: file).accounts, expected)
        XCTAssertThrowsError(try store.renameAccount(original[2].id, to: " \n "))
        XCTAssertThrowsError(try store.renameAccount(original[2].id, to: String(repeating: "x", count: 61)))
        XCTAssertThrowsError(try store.renameAccount(UUID(), to: "Missing"))
        XCTAssertEqual(store.accounts, expected)
    }

    @MainActor func testThemePersistsIndependentlyAndPreviewDoesNotOverwriteIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("quotabar-theme-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("accounts.json")
        let store = Store(accountsFile: file)
        var applied: [AppTheme] = []
        store.onThemeChanged = { applied.append($0) }
        XCTAssertEqual(store.theme, .system)
        try store.setTheme(.dark)
        XCTAssertEqual(applied, [.dark])
        XCTAssertEqual(Store(accountsFile: file).theme, .dark)
        let preview = Store(ephemeral: true, accountsFile: file)
        try preview.setTheme(.light)
        XCTAssertEqual(preview.theme, .light)
        XCTAssertEqual(Store(accountsFile: file).theme, .dark)
        try store.setTheme(.system)
        XCTAssertEqual(Store(accountsFile: file).theme, .system)
        XCTAssertNil(store.theme.appearance)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "Theme settings do not create or rewrite accounts")
    }

    @MainActor func testFiveAccountHomeAndSettingsNavigation() throws {
        let store = Store(ephemeral: true)
        for account in Account.samples { try store.saveAccount(account, key: "") }
        XCTAssertFalse(store.showingAccountDetails)
        XCTAssertEqual(store.visibleAccounts.count, 5)
        let fifth = store.accounts[4]
        store.openAccount(fifth)
        XCTAssertTrue(store.showingAccountDetails)
        XCTAssertEqual(store.selectedAccount?.id, fifth.id)
        store.showHome()
        XCTAssertFalse(store.showingAccountDetails)
        store.showingSettings = true
        store.startEditing(fifth)
        XCTAssertTrue(store.showingEditor)
        XCTAssertFalse(store.showingSettings)
        store.closeEditor()
        XCTAssertTrue(store.showingSettings)
        store.showHome()
        XCTAssertEqual(store.visibleAccounts.count, 5)
    }
}
