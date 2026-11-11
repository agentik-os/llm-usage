import XCTest
@testable import OpenAIQuotaBar

final class ClaudeRolloverTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func account(_ name: String, session: Int? = nil, weekly: Int? = nil, scoped: Int? = nil, pooled: Bool = true,
                         updated: TimeInterval = -60, resets: TimeInterval = 3600) -> Account {
        var account = Account(name: name, provider: .claude)
        account.connection = .claude
        account.claudeConfigDir = "/tmp/\(name)"
        account.inRollover = pooled ? true : nil
        account.lastUpdated = now.addingTimeInterval(updated)
        let reset = Int(now.addingTimeInterval(resets).timeIntervalSince1970)
        account.claudeUsage = ClaudeUsage(
            session: session.map { .init(usedPercent: $0, windowDurationMins: 300, resetsAt: reset) },
            weekly: weekly.map { .init(usedPercent: $0, windowDurationMins: 10080, resetsAt: reset) },
            scoped: scoped.map { [.init(name: "Fable", window: .init(usedPercent: $0, windowDurationMins: 10080, resetsAt: reset))] } ?? [])
        return account
    }

    func testUsedIsTheHighestShareAcrossEveryLimit() {
        XCTAssertEqual(ClaudeRollover.used(account("a", session: 20, weekly: 60), now: now), 60)
        XCTAssertEqual(ClaudeRollover.used(account("a", session: 96, weekly: 60), now: now), 96)
        XCTAssertEqual(ClaudeRollover.used(account("a", session: 10, weekly: 20, scoped: 97), now: now), 97, "a per-model limit blocks that model")
        XCTAssertEqual(ClaudeRollover.used(account("a", weekly: 140), now: now), 100)
        XCTAssertNil(ClaudeRollover.used(account("a"), now: now), "unknown usage is never treated as free")
        var codex = Account(name: "c", provider: .openai); codex.connection = .codex
        XCTAssertNil(ClaudeRollover.used(codex, now: now))
    }

    func testAWindowPastItsResetCountsAsReset() {
        XCTAssertEqual(ClaudeRollover.used(account("a", session: 100, resets: -10), now: now), 0)
    }

    func testDueAtTheThresholdOnly() {
        XCTAssertFalse(ClaudeRollover.isDue(account("a", session: 94, weekly: 50), threshold: 95, now: now))
        XCTAssertTrue(ClaudeRollover.isDue(account("a", session: 95, weekly: 50), threshold: 95, now: now))
        XCTAssertTrue(ClaudeRollover.isDue(account("a", session: 91, weekly: 50), threshold: 90, now: now))
        XCTAssertFalse(ClaudeRollover.isDue(account("a"), threshold: 90, now: now), "no reading, no rollover")
    }

    func testOnlyChosenHealthyAccountsBelowTheThresholdAreAvailable() {
        XCTAssertTrue(ClaudeRollover.isAvailable(account("a", session: 10, weekly: 94), threshold: 95, now: now))
        XCTAssertFalse(ClaudeRollover.isAvailable(account("a", session: 10, weekly: 95), threshold: 95, now: now))
        XCTAssertFalse(ClaudeRollover.isAvailable(account("a", session: 10, weekly: 10, pooled: false), threshold: 95, now: now), "never an account the user left out")
        XCTAssertFalse(ClaudeRollover.isAvailable(account("a", session: 10, updated: -3600), threshold: 95, now: now), "stale usage is not trusted")
        XCTAssertFalse(ClaudeRollover.isAvailable(account("a"), threshold: 95, now: now))
        var failing = account("a", session: 10); failing.error = "Sign in again"
        XCTAssertFalse(ClaudeRollover.isAvailable(failing, threshold: 95, now: now))
        var expired = account("a", session: 10); expired.claudeSignInExpiresAt = now.addingTimeInterval(-1)
        XCTAssertFalse(ClaudeRollover.isAvailable(expired, threshold: 95, now: now))
        var local = account("a", session: 10); local.claudeConfigDir = nil
        XCTAssertFalse(ClaudeRollover.isAvailable(local, threshold: 95, now: now), "no private sign-in to move Claude Code to")
    }

    func testCandidatesPreferTheMostUsageLeftAndSkipTheActiveAccount() {
        let active = account("active", session: 97, weekly: 40)
        let half = account("half", session: 10, weekly: 50)
        let fresh = account("fresh", session: 0, weekly: 5)
        let tie = account("tie", session: 5, weekly: 0)
        let full = account("full", session: 0, weekly: 100)
        let excluded = account("excluded", session: 0, weekly: 0, pooled: false)
        let names = ClaudeRollover.candidates([active, half, fresh, tie, full, excluded], excluding: active.id, threshold: 95, now: now).map(\.name)
        XCTAssertEqual(names, ["fresh", "tie", "half"])
        XCTAssertTrue(ClaudeRollover.candidates([active, full, excluded], excluding: active.id, threshold: 95, now: now).isEmpty)
    }

    @MainActor func testSettingsAndMembershipPersistAndOldFilesStillLoad() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("quotabar-rollover-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("accounts.json")
        let (first, second) = (account("first", session: 10), account("second", session: 20, pooled: false))
        try JSONEncoder().encode([first, second]).write(to: file)
        // Settings written before rollover existed carry only the theme.
        try Data(#"{"theme":"dark"}"#.utf8).write(to: root.appendingPathComponent("settings.json"))

        let store = Store(accountsFile: file)
        XCTAssertEqual(store.theme, .dark)
        XCTAssertEqual(store.rollover, RolloverSettings(), "rollover is off until the user turns it on")
        XCTAssertFalse(store.rollover.enabled)
        try store.setInRollover(second.id, true)
        try store.setInRollover(first.id, false)
        try store.setTheme(.light)
        XCTAssertEqual(store.rollover, RolloverSettings())
        var settings = RolloverSettings(); settings.threshold = 90
        try store.setRollover(settings)
        try store.setTheme(.dark)

        let reloaded = Store(accountsFile: file)
        XCTAssertEqual(reloaded.rollover.threshold, 90, "changing the theme keeps the rollover choice")
        XCTAssertEqual(reloaded.theme, .dark)
        XCTAssertEqual(reloaded.accounts.map { $0.inRollover == true }, [false, true])
        XCTAssertEqual(reloaded.rolloverAccounts.count, 2)
        settings.threshold = 400
        try reloaded.setRollover(settings)
        XCTAssertEqual(reloaded.rollover.threshold, 100)
    }

    func testAccountsSavedBeforeRolloverDecode() throws {
        var legacy = Account(name: "Claude", provider: .claude); legacy.connection = .claude
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        object.removeValue(forKey: "inRollover")
        let decoded = try JSONDecoder().decode(Account.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.inRollover)
    }
}

/// Opt-in live check with real sign-ins and an isolated Claude Code directory, so no real session moves:
/// LLM_USAGE_LIVE_ROLLOVER_FROM is the private dir of an account at or above 95%, _TO one with usage left,
/// _TARGET the isolated directory that stands in for Claude Code.
final class LiveClaudeRolloverTests: XCTestCase {
    @MainActor func testRolloverLeavesAFullAccountForAChosenOneOnly() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let from = environment["LLM_USAGE_LIVE_ROLLOVER_FROM"], let to = environment["LLM_USAGE_LIVE_ROLLOVER_TO"],
              let dir = environment["LLM_USAGE_LIVE_ROLLOVER_TARGET"] else { throw XCTSkip("live check not requested") }
        let target = ClaudeSwitch.Target.directory(dir)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["numStartups": 1]).write(to: target.configFile)
        func email(_ source: String) async throws -> String {
            try await XCTUnwrapAsync(ClaudeSwitch.identify(ClaudeAuth.read(configDir: source)).account?.email)
        }
        let (fromEmail, toEmail) = (try await email(from), try await email(to))
        try await ClaudeSwitch.activate(privateDir: from, expectedEmail: fromEmail, target: target)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("quotabar-live-rollover-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var full = Account(name: "Full", provider: .claude); full.connection = .claude; full.claudeConfigDir = from; full.email = fromEmail
        var spare = Account(name: "Spare", provider: .claude); spare.connection = .claude; spare.claudeConfigDir = to; spare.email = toEmail
        try JSONEncoder().encode([full, spare]).write(to: root.appendingPathComponent("accounts.json"))
        let store = Store(accountsFile: root.appendingPathComponent("accounts.json"), claudeTarget: target)

        await store.refreshAll()
        XCTAssertTrue(store.isClaudeCodeAccount(store.accounts[0]))
        let used = store.accounts.map { ClaudeRollover.used($0) }
        print("LIVE usage full/spare", used)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(used[0]), 95)
        XCTAssertLessThan(try XCTUnwrap(used[1]), 95)

        // On, but the spare account is not chosen: Claude Code stays and the reason is shown.
        var settings = RolloverSettings(); settings.enabled = true
        try store.setRollover(settings)
        await store.evaluateRollover()
        XCTAssertTrue(store.isClaudeCodeAccount(store.accounts[0]), "an account left out of rollover is never used")
        XCTAssertNil(store.rolloverEvent)
        print("LIVE notice:", store.rolloverNotice ?? "none")
        XCTAssertNotNil(store.rolloverNotice)

        // Chosen: the next evaluation moves Claude Code to it.
        try store.setInRollover(store.accounts[1].id, true)
        await store.evaluateRollover()
        XCTAssertTrue(store.isClaudeCodeAccount(store.accounts[1]))
        XCTAssertEqual(store.rolloverEvent?.to, "Spare")
        XCTAssertNil(store.rolloverNotice)
        let confirmed = try await ClaudeSwitch.identify(ClaudeAuth.read(configDir: dir)).account?.email
        XCTAssertEqual(confirmed, toEmail, "Claude confirms the isolated Claude Code now runs on the chosen account")
        XCTAssertEqual(ClaudeSwitch.readAccountInfo(target)?["emailAddress"] as? String, toEmail)

        // Below the threshold now: nothing further happens.
        let event = store.rolloverEvent
        await store.evaluateRollover()
        XCTAssertEqual(store.rolloverEvent, event)
        XCTAssertTrue(store.isClaudeCodeAccount(store.accounts[1]))
        print("LIVE rolled over:", store.rolloverEvent.map { "\($0.from) -> \($0.to)" } ?? "none")
    }
}

private func XCTUnwrapAsync<T>(_ value: T?) throws -> T { try XCTUnwrap(value) }
