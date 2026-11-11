import XCTest
@testable import OpenAIQuotaBar

final class ClaudeSwitchTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("claude-switch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private func writeConfig(_ object: [String: Any], in dir: URL? = nil) throws -> ClaudeSwitch.Target {
        let target = ClaudeSwitch.Target.directory((dir ?? directory).path)
        try JSONSerialization.data(withJSONObject: object).write(to: target.configFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.configFile.path)
        return target
    }
    private func config(_ target: ClaudeSwitch.Target) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: target.configFile)) as? [String: Any])
    }

    func testAccountInfoIsReplacedAndEverythingElseIsKept() throws {
        let target = try writeConfig(["oauthAccount": ["emailAddress": "old@example.com", "organizationUuid": "org-old"],
                                      "numStartups": 412, "projects": ["/tmp/a": ["allowedTools": ["Bash"]]], "url": "https://example.com/a/b"])
        try ClaudeSwitch.writeAccountInfo(["emailAddress": "new@example.com", "organizationUuid": "org-new"], target: target)
        let saved = try config(target)
        XCTAssertEqual(saved["oauthAccount"] as? [String: String], ["emailAddress": "new@example.com", "organizationUuid": "org-new"])
        XCTAssertEqual(saved["numStartups"] as? Int, 412)
        XCTAssertEqual(((saved["projects"] as? [String: Any])?["/tmp/a"] as? [String: [String]])?["allowedTools"], ["Bash"])
        XCTAssertEqual(saved["url"] as? String, "https://example.com/a/b")
        XCTAssertFalse(String(decoding: try Data(contentsOf: target.configFile), as: UTF8.self).contains(#"\/"#), "paths stay readable")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: target.configFile.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.configFile.path + ".lock"), "Claude Code's settings lock is released")
        XCTAssertEqual(ClaudeSwitch.readAccountInfo(target)?["emailAddress"] as? String, "new@example.com")
    }

    func testUnchangedAccountInfoLeavesTheFileAlone() throws {
        let target = try writeConfig(["oauthAccount": ["emailAddress": "same@example.com"], "numStartups": 1])
        let before = try Data(contentsOf: target.configFile)
        try ClaudeSwitch.writeAccountInfo(["emailAddress": "same@example.com"], target: target)
        XCTAssertEqual(try Data(contentsOf: target.configFile), before)
    }

    func testUnreadableSettingsAreNeverOverwritten() throws {
        let target = ClaudeSwitch.Target.directory(directory.path)
        try Data("{ not json".utf8).write(to: target.configFile)
        XCTAssertThrowsError(try ClaudeSwitch.writeAccountInfo(["emailAddress": "new@example.com"], target: target))
        XCTAssertEqual(try Data(contentsOf: target.configFile), Data("{ not json".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.configFile.path + ".lock"))
    }

    func testAccountInfoPrefersTheRecordSavedAtSignIn() throws {
        let profile = try JSONDecoder().decode(ClaudeProfile.self, from: Data(#"{"account":{"email":"A@Example.com","uuid":"acc-1","display_name":"A"},"organization":{"uuid":"org-1","name":"Org","organization_type":"claude_max","rate_limit_tier":"default_claude_max_20x"}}"#.utf8))
        _ = try writeConfig(["oauthAccount": ["emailAddress": "a@example.com", "billingType": "stripe_subscription"]])
        XCTAssertEqual(ClaudeSwitch.accountInfo(privateDir: directory.path, profile: profile)["billingType"] as? String, "stripe_subscription")

        // A record for another account is never reused: Claude's profile is the fallback.
        _ = try writeConfig(["oauthAccount": ["emailAddress": "other@example.com", "billingType": "stale"]])
        let info = ClaudeSwitch.accountInfo(privateDir: directory.path, profile: profile)
        XCTAssertNil(info["billingType"])
        XCTAssertEqual(info["emailAddress"] as? String, "A@Example.com")
        XCTAssertEqual(info["accountUuid"] as? String, "acc-1")
        XCTAssertEqual(info["organizationUuid"] as? String, "org-1")
    }

    func testSameAccountIgnoresCaseAndRejectsMissingEmails() {
        XCTAssertTrue(ClaudeSwitch.sameAccount("A@Example.com", "a@example.com"))
        XCTAssertFalse(ClaudeSwitch.sameAccount("a@example.com", "b@example.com"))
        XCTAssertFalse(ClaudeSwitch.sameAccount(nil, nil))
        XCTAssertFalse(ClaudeSwitch.sameAccount("", ""))
    }

    func testDefaultTargetIsPlainClaudeCode() {
        XCTAssertNil(ClaudeSwitch.Target.claudeCode.configDir)
        XCTAssertEqual(ClaudeSwitch.Target.claudeCode.configFile.lastPathComponent, ".claude.json")
        XCTAssertEqual(ClaudeSwitch.Target.directory("/tmp/x").configFile.path, "/tmp/x/.claude.json")
    }

    func testCredentialDigestIdentifiesATokenWithoutContainingIt() {
        let credentials = ClaudeAuth.Credentials(accessToken: "secret-token", refreshToken: nil, expiresAt: nil, subscriptionType: nil,
                                                 document: ["claudeAiOauth": ["accessToken": "secret-token"], "mcpOAuth": ["server": "kept"]])
        XCTAssertEqual(credentials.digest.count, 64)
        XCTAssertFalse(credentials.digest.contains("secret"))
        XCTAssertEqual(credentials.oauth["accessToken"] as? String, "secret-token")
        XCTAssertNil(credentials.oauth["mcpOAuth"], "only the sign-in is copied between Keychain items")
    }

    @MainActor func testOnlyTheMatchingAccountIsMarkedAsClaudeCodes() throws {
        let store = Store(ephemeral: true)
        var local = Account(name: "Local", provider: .claude); local.connection = .claude
        var other = Account(name: "Other", provider: .claude); other.connection = .claude
        other.claudeConfigDir = "/tmp/other"; other.email = "other@example.com"
        var codex = Account(name: "Codex", provider: .openai); codex.connection = .codex; codex.email = "other@example.com"
        XCTAssertTrue(store.isClaudeCodeAccount(local), "an account read from this Mac's Claude Code is that sign-in")
        XCTAssertFalse(store.isClaudeCodeAccount(other), "nothing is marked before Claude confirmed the sign-in")
        XCTAssertFalse(store.isClaudeCodeAccount(codex))
        XCTAssertFalse(store.canSwitchClaudeCode, "the preview never touches Claude Code")
    }
}

/// Opt-in live check against real sign-ins and an isolated Claude Code directory:
/// LLM_USAGE_LIVE_SWITCH_FROM / _TO are private config dirs, LLM_USAGE_LIVE_SWITCH_TARGET the directory switched.
final class LiveClaudeSwitchTests: XCTestCase {
    func testSwitchReplacesOnlyTheSignInAndIsConfirmedByClaude() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let from = environment["LLM_USAGE_LIVE_SWITCH_FROM"], let to = environment["LLM_USAGE_LIVE_SWITCH_TO"],
              let dir = environment["LLM_USAGE_LIVE_SWITCH_TARGET"] else { throw XCTSkip("live check not requested") }
        let target = ClaudeSwitch.Target.directory(dir)
        // Claude Code's real item also holds MCP tokens and is far larger than one `security -i` line.
        let filler = String(repeating: "x", count: 60_000)
        try await ClaudeAuth.store(["claudeAiOauth": ["accessToken": "placeholder"], "mcpOAuth": ["server": filler]], configDir: dir)
        if !FileManager.default.fileExists(atPath: target.configFile.path) {
            try JSONSerialization.data(withJSONObject: ["numStartups": 7]).write(to: target.configFile)
        }
        for source in [from, to] {
            let expected = try await ClaudeSwitch.identify(ClaudeAuth.read(configDir: source)).account?.email
            let active = try await ClaudeSwitch.activate(privateDir: source, expectedEmail: expected, target: target)
            let confirmed = try await ClaudeSwitch.identify(active).account?.email
            XCTAssertEqual(confirmed, expected)
            XCTAssertEqual(ClaudeSwitch.readAccountInfo(target)?["emailAddress"] as? String, expected)
            let document = await ClaudeAuth.readDocument(configDir: dir)
            XCTAssertEqual((document?["mcpOAuth"] as? [String: String])?["server"]?.count, 60_000, "other Keychain entries survive")
            let privateToken = try await ClaudeAuth.read(configDir: source).accessToken
            XCTAssertEqual(active.accessToken, privateToken, "Claude Code and the private copy share one sign-in")
            print("LIVE switched to account ending", expected?.suffix(18) ?? "?", "digest", active.digest.prefix(8))
        }
        do {
            _ = try await ClaudeSwitch.activate(privateDir: to, expectedEmail: "someone-else@example.com", target: target)
            XCTFail("a sign-in for another account must be refused")
        } catch { }
    }
}
