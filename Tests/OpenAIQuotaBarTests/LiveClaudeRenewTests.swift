import XCTest
@testable import OpenAIQuotaBar

/// Opt-in live check: LLM_USAGE_LIVE_CLAUDE_DIR=<private config dir> renews that sign-in for real.
final class LiveClaudeRenewTests: XCTestCase {
    func testRenewRotatesAndKeepsAccountUsable() async throws {
        guard let dir = ProcessInfo.processInfo.environment["LLM_USAGE_LIVE_CLAUDE_DIR"] else { throw XCTSkip("live check not requested") }
        let before = try await ClaudeAuth.read(configDir: dir)
        let after = try await ClaudeAuth.renew(before, configDir: dir)
        XCTAssertNotEqual(before.accessToken, after.accessToken)
        XCTAssertNotEqual(before.refreshToken, after.refreshToken)
        let refreshExpiry = (after.document["claudeAiOauth"] as? [String: Any])?["refreshTokenExpiresAt"] as? Double
        print("LIVE access expires in", Int(after.expiresAt!.timeIntervalSinceNow / 3600), "h; refresh expires in",
              refreshExpiry.map { String(format: "%.1f days", ($0 / 1000 - Date().timeIntervalSince1970) / 86400) } ?? "unknown")
        let usage = ClaudeUsage(try await ClaudeAuth.get(ClaudeAuth.usageURL, token: after.accessToken, as: ClaudeUsage.Response.self))
        print("LIVE reply fields", ClaudeAuth.lastRenewalFields)
        print("LIVE weekly used", usage.weekly?.usedPercent ?? -1)
        let reread = try await ClaudeAuth.read(configDir: dir)
        XCTAssertEqual(reread.accessToken, after.accessToken)
    }
}
