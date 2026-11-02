import XCTest
@testable import OpenAIQuotaBar

final class ClaudeTests: XCTestCase {
    func testUsageResponseMapsSessionWeeklyAndScopedWindows() throws {
        let data = Data(#"{"five_hour":{"utilization":38.0,"resets_at":"2026-11-02T17:09:59.570006+00:00"},"seven_day":{"utilization":69.4,"resets_at":"2026-11-06T11:59:59+00:00"},"seven_day_opus":null,"extra_usage":{"utilization":null},"limits":[{"kind":"session","percent":38},{"kind":"weekly_scoped","percent":0,"resets_at":"2026-11-06T12:00:00+00:00","scope":{"model":{"id":null,"display_name":"Fable"}}}],"unknown_future_key":{"x":1}}"#.utf8)
        let usage = ClaudeUsage(try JSONDecoder().decode(ClaudeUsage.Response.self, from: data))
        XCTAssertEqual(usage.session?.usedPercent, 38)
        XCTAssertEqual(usage.session?.title, "5-hour")
        XCTAssertEqual(usage.session?.resetsAt, 1793639399)
        XCTAssertEqual(usage.weekly?.usedPercent, 69)
        XCTAssertEqual(usage.weekly?.title, "Weekly")
        XCTAssertEqual(usage.scoped, [.init(name: "Fable", window: .init(usedPercent: 0, windowDurationMins: 10080, resetsAt: 1793966400))])
    }
    func testMissingUtilizationIsNotZeroUsage() throws {
        let usage = ClaudeUsage(try JSONDecoder().decode(ClaudeUsage.Response.self, from: Data(#"{"five_hour":{"utilization":null,"resets_at":null}}"#.utf8)))
        XCTAssertNil(usage.session)
        XCTAssertNil(usage.weekly)
        var account = Account(name: "Claude", provider: .claude)
        account.connection = .claude
        account.claudeUsage = usage
        XCTAssertNil(account.quotaFraction)
    }
    func testClaudeAccountUsesSessionWindowAndRoundTrips() throws {
        var account = Account(name: "Claude", provider: .claude)
        account.connection = .claude
        account.planType = "Max 20x"
        account.claudeUsage = ClaudeUsage(session: .init(usedPercent: 25, windowDurationMins: 300), weekly: .init(usedPercent: 60, windowDurationMins: 10080))
        XCTAssertEqual(account.quotaFraction, 0.4, "the weekly window is the binding limit")
        XCTAssertEqual(account.primaryWindow?.title, "Weekly")
        XCTAssertEqual(account.secondaryWindow?.remainingPercent, 75)
        account.claudeUsage = ClaudeUsage(session: nil, weekly: .init(usedPercent: 100, windowDurationMins: 10080))
        XCTAssertEqual(account.quotaFraction, 0, "an exhausted weekly limit is shown, not missing data")
        XCTAssertNil(account.secondaryWindow)
        XCTAssertEqual(account.planLabel, "Max 20x · Claude Code")
        XCTAssertFalse(account.isCodex)
        let decoded = try JSONDecoder().decode([Account].self, from: JSONEncoder().encode([account]))
        XCTAssertEqual(decoded, [account])
    }
    func testProfilePlanName() throws {
        let profile = try JSONDecoder().decode(ClaudeProfile.self, from: Data(#"{"account":{"email":"a@b.c"},"organization":{"organization_type":"claude_max","rate_limit_tier":"default_claude_max_20x"}}"#.utf8))
        XCTAssertEqual(profile.planName, "Max 20x")
    }
    func testKeychainServiceNaming() {
        XCTAssertEqual(ClaudeAuth.service(configDir: nil), "Claude Code-credentials")
        XCTAssertTrue(ClaudeAuth.service(configDir: "/tmp/x").hasPrefix("Claude Code-credentials-"))
        XCTAssertEqual(ClaudeAuth.service(configDir: "/tmp/x").count, "Claude Code-credentials-".count + 8)
    }
}

final class ClaudeSignInExpiryTests: XCTestCase {
    func testWarnsOnlyInTheLastThreeDays() {
        var account = Account(name: "Claude", provider: .claude)
        account.connection = .claude
        account.claudeSignInExpiresAt = Date().addingTimeInterval(20 * 86400)
        XCTAssertNil(account.claudeSignInDaysLeft)
        account.claudeSignInExpiresAt = Date().addingTimeInterval(2.5 * 86400)
        XCTAssertEqual(account.claudeSignInDaysLeft, 3)
        account.claudeSignInExpiresAt = Date().addingTimeInterval(-60)
        XCTAssertEqual(account.claudeSignInDaysLeft, 0)
    }
}
