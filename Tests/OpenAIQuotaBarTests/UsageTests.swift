import XCTest
@testable import OpenAIQuotaBar

final class UsageTests: XCTestCase {
    func testUnfetchedUsageDoesNotClaimFullBudget() {
        let account = Account(name: "New", provider: .openai, monthlyLimit: 2_000_000)
        XCTAssertNil(account.remaining)
        XCTAssertNil(account.remainingFraction)
    }
    func testBudgetIsClampedAndOptional() {
        var account = Account(name: "Account", provider: .openai, monthlyLimit: 100, usedTokens: 120, lastUpdated: Date())
        XCTAssertEqual(account.remaining, 0)
        XCTAssertEqual(account.remainingFraction, 0)
        account.monthlyLimit = 0
        XCTAssertNil(account.remaining)
        account.monthlyLimit = nil
        XCTAssertNil(account.remainingFraction)
    }
    func testExistingAccountStorageIsCompatible() throws {
        let data = Data(#"[{"id":"11111111-1111-1111-1111-111111111111","name":"Old account","provider":"OpenAI","monthlyLimit":1000,"resetCredits":2,"usedTokens":200}]"#.utf8)
        let accounts = try JSONDecoder().decode([Account].self, from: data)
        XCTAssertEqual(accounts[0].monthlyLimit, 1000)
        XCTAssertEqual(accounts[0].resetCredits, 2)
        XCTAssertEqual(try JSONDecoder().decode([Account].self, from: JSONEncoder().encode(accounts)), accounts)
    }
    func testUsageSumsAllBucketsAndBothTokenDirections() throws {
        let data = Data(#"{"data":[{"results":[{"input_tokens":100,"output_tokens":25},{"input_tokens":30,"output_tokens":5}]},{"results":[]},{"results":[{"input_tokens":10,"output_tokens":2}]}],"has_more":false,"next_page":null}"#.utf8)
        let page = try JSONDecoder().decode(OpenAIUsage.Page.self, from: data)
        XCTAssertEqual(page.total, 172)
    }
    func testMalformedUsageDoesNotBecomeZeroUsage() {
        XCTAssertThrowsError(try JSONDecoder().decode(OpenAIUsage.Page.self, from: Data(#"{"error":"invalid"}"#.utf8)))
    }
    @MainActor func testPreviewDoesNotMixSampleAndRealAccounts() throws {
        let store = Store(ephemeral: true)
        store.showingDemo = true
        XCTAssertEqual(store.visibleAccounts.count, 5)
        XCTAssertTrue(store.accounts.isEmpty)
        let account = Account(name: "Real", provider: .openai)
        try store.saveAccount(account, key: "")
        XCTAssertFalse(store.showingDemo)
        XCTAssertEqual(store.visibleAccounts, [account])
        try store.remove(account)
        XCTAssertNil(store.selectedAccount)
    }
}

final class AccountEmailTests: XCTestCase {
    func testMenuTitleShowsTheEmailOnlyWhenItAddsInformation() {
        var account = Account(name: "Work", provider: .claude)
        XCTAssertEqual(account.menuTitle, "Work")
        account.email = "work@example.com"
        XCTAssertEqual(account.menuTitle, "Work · work@example.com")
        account.name = "work@example.com"
        XCTAssertEqual(account.menuTitle, "work@example.com")
        account.email = ""
        XCTAssertEqual(account.menuTitle, "work@example.com")
    }
}

final class AccountReconnectTests: XCTestCase {
    private func claude(_ name: String, email: String) -> Account {
        var account = Account(name: name, provider: .claude)
        account.connection = .claude
        account.claudeConfigDir = "/tmp/llm-usage-test-\(UUID())"
        account.email = email
        return account
    }
    @MainActor private func store(_ accounts: [Account]) throws -> (Store, URL) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("llm-usage-reconnect-\(UUID())")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let file = home.appendingPathComponent("accounts.json")
        try JSONEncoder().encode(accounts).write(to: file)
        return (Store(accountsFile: file, openBrowser: { _ in true }, claudeTarget: .directory(home.appendingPathComponent("claude").path)), home)
    }
    @MainActor func testReconnectKeepsTheLatestRecordAndItsSettings() throws {
        let original = claude("Work", email: "work@example.com")
        let (store, home) = try store([original])
        defer { store.shutdown(); try? FileManager.default.removeItem(at: home) }
        try store.renameAccount(original.id, to: "Renamed")
        try store.setInRollover(original.id, true)
        let resolved = try XCTUnwrap(store.accountForReconnect(original, authenticatedEmail: "WORK@example.com"))
        XCTAssertEqual(resolved.id, original.id)
        XCTAssertEqual(resolved.name, "Renamed", "a rename made after the reconnect started is kept")
        XCTAssertEqual(resolved.inRollover, true)
    }
    @MainActor func testReconnectRefusesAnotherAccountAndLeavesTheSavedOneAlone() throws {
        let original = claude("Work", email: "work@example.com")
        let (store, home) = try store([original])
        defer { store.shutdown(); try? FileManager.default.removeItem(at: home) }
        XCTAssertThrowsError(try store.accountForReconnect(original, authenticatedEmail: "other@example.com")) {
            XCTAssertTrue($0 is ReconnectIdentityMismatch)
            XCTAssertTrue($0.localizedDescription.contains("work@example.com"))
        }
        XCTAssertEqual(store.accounts, [original])
        XCTAssertNil(try store.accountForReconnect(nil, authenticatedEmail: "new@example.com"), "a new connection is not a reconnect")
    }
    @MainActor func testReconnectOfARemovedAccountFails() throws {
        let original = claude("Work", email: "work@example.com")
        let (store, home) = try store([original])
        defer { store.shutdown(); try? FileManager.default.removeItem(at: home) }
        try store.remove(original)
        XCTAssertThrowsError(try store.accountForReconnect(original, authenticatedEmail: "work@example.com"))
    }
    func testExhaustedModelLimitIsReportedUntilItResets() {
        var account = claude("Work", email: "work@example.com")
        let later = Int(Date().timeIntervalSince1970) + 3600, earlier = Int(Date().timeIntervalSince1970) - 60
        account.claudeUsage = ClaudeUsage(weekly: .init(usedPercent: 54, windowDurationMins: 10080),
                                          scoped: [.init(name: "Fable", window: .init(usedPercent: 100, windowDurationMins: 10080, resetsAt: later))])
        XCTAssertEqual(account.exhaustedModelLimit(), "Fable", "the overall weekly limit has room, the model limit does not")
        account.claudeUsage?.scoped = [.init(name: "Fable", window: .init(usedPercent: 100, windowDurationMins: 10080, resetsAt: earlier))]
        XCTAssertNil(account.exhaustedModelLimit(), "a limit past its reset time counts as reset")
        account.claudeUsage?.scoped = [.init(name: "Fable", window: .init(usedPercent: 90, windowDurationMins: 10080, resetsAt: later))]
        XCTAssertNil(account.exhaustedModelLimit())
    }
}
