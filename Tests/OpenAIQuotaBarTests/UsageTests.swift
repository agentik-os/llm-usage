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
