import XCTest
@testable import OpenAIQuotaBar

final class ProviderConnectionTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("provider-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testFinderEnvironmentDiscoversNpmAndRunsEnvNodeLaunchers() async throws {
        let bin = root.appendingPathComponent(".local/node/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let launcher = bin.appendingPathComponent("codex")
        try Data("#!/usr/bin/env node\n".utf8).write(to: launcher)
        try Data("#!/bin/sh\nprintf 'launcher works'\n".utf8).write(to: bin.appendingPathComponent("node"))
        for name in ["codex", "node"] { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: bin.appendingPathComponent(name).path) }
        let found = CLIEnvironment.executable("codex", home: root, inherited: ["PATH": "/usr/bin:/bin"])
        XCTAssertEqual(found, launcher)
        let process = Process(), output = Pipe()
        process.executableURL = found
        process.environment = CLIEnvironment.environment(inherited: ["PATH": "/usr/bin:/bin"], executable: found)
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "launcher works")
        XCTAssertFalse(CLIEnvironment.directories(home: root, inherited: ["PATH": ":relative:/usr/bin"]).contains("relative"))
    }

    func testClaudeUrlIsCompleteAndOnlyUsesOfficialHosts() {
        let full = "https://claude.ai/oauth/authorize?state=abc&code_challenge=long-challenge"
        XCTAssertNil(ClaudeLoginSession.authorizationURL(in: full), "a split pipe chunk isn't a complete authorization URL")
        XCTAssertEqual(ClaudeLoginSession.authorizationURL(in: "\u{1b}[32m" + full + "\u{1b}[0m\n")?.absoluteString, full)
        XCTAssertNil(ClaudeLoginSession.authorizationURL(in: "https://claude.ai.attacker.test/oauth/authorize?state=abc\n"))
        XCTAssertNil(ClaudeLoginSession.authorizationURL(in: "https://user:secret@claude.ai/oauth/authorize?state=abc\n"))
    }

    func testClaudeLoginDoesNotInheritAnotherProvider() {
        let inherited = ["ANTHROPIC_AUTH_TOKEN": "secret", "ANTHROPIC_API_KEY": "secret", "ANTHROPIC_BASE_URL": "https://example.com",
                         "CLAUDE_CODE_USE_BEDROCK": "1", "CLAUDE_CODE_OAUTH_TOKEN": "secret", "CLAUDE_CONFIG_DIR": "/old", "HOME": "/home"]
        let env = ClaudeLoginSession.environment(configDir: "/private", inherited: inherited)
        XCTAssertEqual(env["CLAUDE_CONFIG_DIR"], "/private")
        XCTAssertEqual(env["HOME"], "/home")
        for key in inherited.keys where key != "HOME" && key != "CLAUDE_CONFIG_DIR" { XCTAssertNil(env[key]) }
    }

    func testClaudeBrowserCallbackCompletesWithoutPastingACode() async throws {
        let script = root.appendingPathComponent("login.py")
        try Data("import time\nprint('https://claude.ai/oauth/authorize?state=test&code_challenge=fixture', flush=True)\ntime.sleep(.1)\n".utf8).write(to: script)
        let session = ClaudeLoginSession(executable: "/usr/bin/python3", configDir: root.appendingPathComponent("profile").path, prefixArguments: [script.path])
        defer { session.cancel() }
        let url = try await session.start()
        XCTAssertEqual(url.host, "claude.ai")
        try await session.waitForCompletion()
    }

    func testClaudeManualCodeAndCancellationReleaseWaiter() async throws {
        let script = root.appendingPathComponent("manual.py")
        try Data("import sys\nprint('https://claude.ai/oauth/authorize?state=test', flush=True)\nline=sys.stdin.readline().strip()\nsys.exit(0 if line == 'fixture-code' else 1)\n".utf8).write(to: script)
        for cancel in [false, true] {
            let session = ClaudeLoginSession(executable: "/usr/bin/python3", configDir: root.appendingPathComponent(UUID().uuidString).path, prefixArguments: [script.path])
            _ = try await session.start()
            let waiter = Task { try await session.waitForCompletion() }
            if cancel { session.cancel() } else { try session.submit(code: "fixture-code") }
            do { try await waiter.value; XCTAssertFalse(cancel) }
            catch { XCTAssertTrue(cancel) }
            session.cancel()
        }
    }

    @MainActor func testSwitchingProviderDiscardsLateClaudeConnection() async throws {
        var profileReply: CheckedContinuation<ClaudeProfile, Error>?
        let credentials = ClaudeAuth.Credentials(accessToken: "fixture", document: [:])
        let store = Store(accountsFile: root.appendingPathComponent("accounts.json"), readClaudeCredentials: { _ in credentials }, fetchClaudeProfile: { _ in
            try await withCheckedThrowingContinuation { profileReply = $0 }
        })
        defer { store.shutdown() }
        store.startClaudeConnect()
        store.useLocalClaudeCode()
        for _ in 0..<100 where profileReply == nil { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertNotNil(profileReply)
        store.cancelClaudeConnect()
        let profile = try JSONDecoder().decode(ClaudeProfile.self, from: Data(#"{"account":{"email":"fixture@example.com"}}"#.utf8))
        profileReply?.resume(returning: profile)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertNil(store.claudeConnect)
        XCTAssertTrue(store.accounts.isEmpty, "a cancelled provider connection must not add an account later")
    }

    @MainActor func testLocalCodexImportRefreshAndDisconnectNeverLogsOutTheCLI() async throws {
        let fixture = Bundle.module.url(forResource: "fake-codex", withExtension: "py", subdirectory: "Fixtures")!
        let localHome = root.appendingPathComponent("local-codex")
        let store = Store(accountsFile: root.appendingPathComponent("accounts.json"), makeLocalClient: {
            try CodexClient(home: localHome, executable: URL(fileURLWithPath: "/usr/bin/python3"), prefixArguments: [fixture.path], credentialStore: nil)
        })
        defer { store.shutdown() }
        store.useLocalCodex()
        for _ in 0..<100 {
            if store.accounts.first?.lastUpdated != nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let account = try XCTUnwrap(store.accounts.first)
        XCTAssertEqual(account.usesLocalCodex, true)
        XCTAssertNil(account.authSessionID)
        XCTAssertEqual(account.codexUsage?.codex.primary?.usedPercent, 28)
        XCTAssertNil(account.error)
        try await store.disconnect(account)
        XCTAssertTrue(store.accounts.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: localHome.appendingPathComponent("logout-called").path))
    }

    @MainActor func testLocalCodexDoesNotShowAnotherAccountsQuota() async throws {
        let fixture = Bundle.module.url(forResource: "fake-codex", withExtension: "py", subdirectory: "Fixtures")!
        let localHome = root.appendingPathComponent("local-codex")
        var account = Account(name: "Old", provider: .openai)
        account.connection = .codex; account.usesLocalCodex = true; account.email = "different@example.com"
        try JSONEncoder().encode([account]).write(to: root.appendingPathComponent("accounts.json"))
        let store = Store(accountsFile: root.appendingPathComponent("accounts.json"), makeLocalClient: {
            try CodexClient(home: localHome, executable: URL(fileURLWithPath: "/usr/bin/python3"), prefixArguments: [fixture.path], credentialStore: nil)
        })
        defer { store.shutdown() }
        await store.refresh(account)
        XCTAssertNotNil(store.accounts.first?.error)
        XCTAssertNil(store.accounts.first?.codexUsage)
    }
}

/// Opt in on a configured Mac. Copies both sign-ins into disposable Keychain namespaces;
/// only the disposable target is switched, never the user's Claude Code installation.
final class LiveProviderConnectionTests: XCTestCase {
    func testRealClaudeAccountsSwitchInAnIsolatedTarget() async throws {
        guard ProcessInfo.processInfo.environment["LLM_USAGE_VALIDATE_CLAUDE_SWITCH"] == "1" else {
            throw XCTSkip("isolated live account check not requested")
        }
        let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenAIQuotaBar/accounts.json")
        let accounts = try JSONDecoder().decode([Account].self, from: Data(contentsOf: file))
        let other = try XCTUnwrap(accounts.first { $0.isClaude && $0.claudeConfigDir != nil })
        let original = try await ClaudeAuth.read(configDir: nil)
        let alternate = try await ClaudeAuth.read(configDir: other.claudeConfigDir)
        guard !original.expires(within: 300), !alternate.expires(within: 300) else {
            throw XCTSkip("sign-ins must be fresh; this test never renews the originals")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("llm-live-claude-\(UUID())")
        let sourceA = root.appendingPathComponent("a").path
        let sourceB = root.appendingPathComponent("b").path
        let target = ClaudeSwitch.Target.directory(root.appendingPathComponent("target").path)
        try FileManager.default.createDirectory(at: target.configFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try await ClaudeSwitch.capture(original, into: sourceA, from: .claudeCode)
            try await ClaudeSwitch.capture(alternate, into: sourceB, from: .directory(other.claudeConfigDir!))
            try JSONSerialization.data(withJSONObject: ["numStartups": 42]).write(to: target.configFile)
            try await ClaudeAuth.store(["claudeAiOauth": ["accessToken": "placeholder"], "mcpOAuth": ["fixture": "preserved"]], configDir: target.configDir)
            var confirmed = Set<String>()
            for source in [sourceA, sourceB, sourceA] {
                let expected = try await ClaudeSwitch.identify(ClaudeAuth.read(configDir: source)).account?.email
                let active = try await ClaudeSwitch.activate(privateDir: source, expectedEmail: expected, target: target)
                let actual = try await ClaudeSwitch.identify(active).account?.email
                XCTAssertTrue(ClaudeSwitch.sameAccount(expected, actual))
                XCTAssertEqual(ClaudeSwitch.readAccountInfo(target)?["emailAddress"] as? String, expected)
                let document = await ClaudeAuth.readDocument(configDir: target.configDir)
                XCTAssertEqual((document?["mcpOAuth"] as? [String: String])?["fixture"], "preserved")
                if let actual { confirmed.insert(actual) }
            }
            XCTAssertEqual(confirmed.count, 2, "two distinct real accounts were verified by Claude")
            let after = try await ClaudeAuth.read(configDir: nil)
            XCTAssertEqual(after.digest, original.digest, "default Claude Code authentication was never changed")
            print("LIVE Claude A → B → A: independently verified; default sign-in and MCP entries preserved")
        } catch {
            for path in [sourceA, sourceB, target.configDir!] { await ClaudeAuth.forget(configDir: path) }
            try? FileManager.default.removeItem(at: root)
            throw error
        }
        for path in [sourceA, sourceB, target.configDir!] { await ClaudeAuth.forget(configDir: path) }
        try? FileManager.default.removeItem(at: root)
    }
}
