import XCTest
@testable import OpenAIQuotaBar

final class CodexTests: XCTestCase {
    @MainActor private func client() throws -> (CodexClient, URL) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("quotabar-test-\(UUID())")
        let fixture = Bundle.module.url(forResource: "fake-codex", withExtension: "py", subdirectory: "Fixtures")!
        return (try CodexClient(home: home, executable: URL(fileURLWithPath: "/usr/bin/python3"), prefixArguments: [fixture.path]), home)
    }
    @MainActor func testFragmentedRPCAndLoginNotifications() async throws {
        let (client, home) = try client()
        defer { client.stop(); try? FileManager.default.removeItem(at: home) }
        try await client.start()
        let identity = try JSONDecoder().decode(CodexIdentity.self, from: await client.request("account/read", params: ["_test": "fragmented"]))
        XCTAssertEqual(identity.account?.planType, "pro")
        let completed = expectation(description: "completion event")
        client.notification = { method, data in
            if method == "account/login/completed" {
                XCTAssertTrue((try? JSONDecoder().decode(LoginCompletion.self, from: data).success) == true)
                completed.fulfill()
            }
        }
        let data = try await client.request("account/login/start", params: ["type": "chatgptDeviceCode"])
        let login = try JSONDecoder().decode(DeviceSignIn.self, from: data)
        XCTAssertEqual(login.browserURL?.host, "auth.openai.com")
        await fulfillment(of: [completed], timeout: 2)
    }
    @MainActor func testTimeoutDisconnectAndErrorRedaction() async throws {
        for behavior in ["timeout", "error", "disconnect"] {
            let (client, home) = try client()
            try await client.start()
            do {
                _ = try await client.request("account/read", params: ["_test": behavior], timeout: 0.2)
                XCTFail("Expected failure for \(behavior)")
            } catch { XCTAssertFalse(error.localizedDescription.contains("secret-value")) }
            client.stop()
            try? FileManager.default.removeItem(at: home)
        }
    }
    @MainActor func testCancellationReleasesPendingRequest() async throws {
        let (client, home) = try client()
        defer { client.stop(); try? FileManager.default.removeItem(at: home) }
        try await client.start()
        let waiting = Task { try await client.request("account/read", params: ["_test": "timeout"], timeout: 10) }
        try await Task.sleep(nanoseconds: 20_000_000)
        waiting.cancel()
        do { _ = try await waiting.value; XCTFail("Should cancel") }
        catch { XCTAssertTrue(error is CancellationError) }
        let response = try await client.request("account/read")
        XCTAssertNotNil(try JSONDecoder().decode(CodexIdentity.self, from: response).account)
    }
    @MainActor func testProfileIsolationAndNoInheritedAuthentication() {
        let first = URL(fileURLWithPath: "/tmp/profile-one")
        let second = URL(fileURLWithPath: "/tmp/profile-two")
        let inherited = ["CODEX_HOME": "/real/codex", "OPENAI_API_KEY": "secret", "CODEX_ACCESS_TOKEN": "secret", "PATH": "/usr/bin", "HOME": "/real/home"]
        let env = CodexClient.environment(for: first, inherited: inherited)
        XCTAssertEqual(env["CODEX_HOME"], first.path)
        XCTAssertNil(env["OPENAI_API_KEY"])
        XCTAssertNil(env["CODEX_ACCESS_TOKEN"])
        XCTAssertEqual(env["HOME"], "/real/home")
        XCTAssertNotEqual(env["CODEX_HOME"], CodexClient.environment(for: second, inherited: inherited)["CODEX_HOME"])
    }
    func testOnlyOfficialHTTPSBrowserLinksAreAllowed() {
        for url in ["http://auth.openai.com/codex/device", "https://auth.openai.com.evil.example/device", "https://user:password@auth.openai.com/codex/device", "file:///tmp/test"] {
            let login = DeviceSignIn(type: "chatgptDeviceCode", loginId: "test", verificationUrl: url, userCode: "TEST", authUrl: nil)
            XCTAssertNil(login.browserURL)
        }
    }
    func testUsageSelectsCodexBucketAndPreservesUnavailableFields() throws {
        let json = #"{"rateLimits":{"limitId":"other","primary":{"usedPercent":99}},"rateLimitsByLimitId":{"codex":{"limitId":"codex","primary":{"usedPercent":28,"windowDurationMins":300,"resetsAt":2000000000}}}}"#
        let usage = try JSONDecoder().decode(CodexUsage.self, from: Data(json.utf8))
        XCTAssertEqual(usage.codex.primary?.remainingPercent, 72)
        XCTAssertEqual(usage.codex.primary?.title, "5-hour")
        XCTAssertNil(usage.rateLimitResetCredits)
        XCTAssertNil(usage.codex.secondary)
        var wrongBucket = usage
        wrongBucket.rateLimitsByLimitId = nil
        XCTAssertNil(wrongBucket.codex.primary)
        XCTAssertEqual(CodexUsage.Window(usedPercent: 140).remainingPercent, 0)
        XCTAssertEqual(CodexUsage.Window(usedPercent: -20).remainingPercent, 100)
    }
    @MainActor func testPreviewSignInHasNoFormAndCanBeCancelled() {
        let store = Store(ephemeral: true)
        store.startAdding()
        guard case let .waiting(challenge) = store.signInState else { return XCTFail("Expected preview code") }
        XCTAssertEqual(challenge.userCode, "DEMO-1234")
        XCTAssertFalse(store.showingEditor)
        XCTAssertTrue(store.accounts.isEmpty)
        store.cancelSignIn()
        XCTAssertNil(store.signInState)
        XCTAssertTrue(store.accounts.isEmpty)
    }
    @MainActor func testCompletedLoginAddsAccountAndLoadsRealProtocolFields() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("quotabar-store-test-\(UUID())")
        let fixture = Bundle.module.url(forResource: "fake-codex", withExtension: "py", subdirectory: "Fixtures")!
        var opened: [URL] = []
        let store = Store(accountsFile: home.appendingPathComponent("accounts.json"), makeClient: {
            try CodexClient(home: $0, executable: URL(fileURLWithPath: "/usr/bin/python3"), prefixArguments: [fixture.path])
        }, openBrowser: { opened.append($0); return true })
        defer { store.shutdown(); try? FileManager.default.removeItem(at: home) }
        store.startAdding()
        for _ in 0..<100 {
            if store.accounts.first?.lastUpdated != nil { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let account = try XCTUnwrap(store.accounts.first)
        XCTAssertTrue(account.isCodex)
        XCTAssertNotNil(account.authSessionID)
        XCTAssertEqual(account.planType, "pro")
        XCTAssertEqual(account.codexUsage?.codex.primary?.remainingPercent, 72)
        XCTAssertEqual(account.codexUsage?.rateLimitResetCredits?.availableCount, 2)
        XCTAssertNil(store.signInState)
        XCTAssertNil(account.error)
        XCTAssertTrue(opened.allSatisfy { $0.host == "auth.openai.com" })
        let saved = try String(contentsOf: home.appendingPathComponent("accounts.json"))
        XCTAssertFalse(saved.contains("TEST-CODE"))
        XCTAssertFalse(saved.contains("access_token"))
    }
    @MainActor func testCancelledLoginNeverAddsAnAccount() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("quotabar-cancel-test-\(UUID())")
        let fixture = Bundle.module.url(forResource: "fake-codex", withExtension: "py", subdirectory: "Fixtures")!
        let store = Store(accountsFile: home.appendingPathComponent("accounts.json"), makeClient: {
            try CodexClient(home: $0, executable: URL(fileURLWithPath: "/usr/bin/python3"), prefixArguments: [fixture.path, "--no-complete"])
        }, openBrowser: { _ in true })
        defer { store.shutdown(); try? FileManager.default.removeItem(at: home) }
        store.startAdding()
        for _ in 0..<100 {
            if case .waiting = store.signInState { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard case .waiting = store.signInState else { return XCTFail("No device challenge") }
        store.cancelSignIn()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(store.signInState)
        XCTAssertTrue(store.accounts.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("accounts.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("pending-signin.json").path))
    }

    @MainActor func testLoginReloadsSavedCredentialsAndWaitsForAccountPublication() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("quotabar-handoff-test-\(UUID())")
        let fixture = Bundle.module.url(forResource: "fake-codex", withExtension: "py", subdirectory: "Fixtures")!
        var profiles: [URL] = []
        var browserOpens = 0
        let store = Store(accountsFile: home.appendingPathComponent("accounts.json"), makeClient: {
            profiles.append($0)
            return try CodexClient(home: $0, executable: URL(fileURLWithPath: "/usr/bin/python3"), prefixArguments: [fixture.path, "--stale-after-login", "--delayed-account"])
        }, openBrowser: { _ in browserOpens += 1; return true })
        defer { store.shutdown(); try? FileManager.default.removeItem(at: home) }
        store.startAdding()
        for _ in 0..<160 {
            if store.accounts.first?.lastUpdated != nil { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(store.accounts.count, 1)
        XCTAssertNotNil(store.accounts.first?.lastUpdated)
        XCTAssertNil(store.signInState)
        XCTAssertFalse(store.canResumeSignIn)
        XCTAssertEqual(Set(profiles).count, 1, "The approved profile must be reused")
        XCTAssertGreaterThanOrEqual(profiles.count, 5, "Login, fresh account readers, then usage")
        XCTAssertLessThanOrEqual(browserOpens, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("pending-signin.json").path))
    }

    @MainActor func testInterruptedSignInResumesWithoutOpeningBrowserOrDuplicatingAccount() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("quotabar-resume-test-\(UUID())")
        let sessionID = UUID()
        let pending = Store.PendingSignIn(sessionID: sessionID, reconnectID: nil)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let marker = home.appendingPathComponent("pending-signin.json")
        try JSONEncoder().encode(pending).write(to: marker)
        let fixture = Bundle.module.url(forResource: "fake-codex", withExtension: "py", subdirectory: "Fixtures")!
        var available = false
        var browserOpens = 0
        let store = Store(accountsFile: home.appendingPathComponent("accounts.json"), makeClient: {
            try CodexClient(home: $0, executable: URL(fileURLWithPath: "/usr/bin/python3"), prefixArguments: [fixture.path] + (available ? [] : ["--account-unavailable"]))
        }, openBrowser: { _ in browserOpens += 1; return true })
        defer { store.shutdown(); try? FileManager.default.removeItem(at: home) }
        store.resumePendingSignIn()
        for _ in 0..<160 {
            if case .failed = store.signInState { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard case .failed = store.signInState else { return XCTFail("Expected recoverable failure") }
        XCTAssertTrue(store.canResumeSignIn)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        available = true
        store.retrySignIn()
        for _ in 0..<100 {
            if store.accounts.first?.lastUpdated != nil { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(store.accounts.count, 1)
        XCTAssertEqual(store.accounts.first?.authSessionID, sessionID)
        XCTAssertNil(store.signInState)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        // A stale recovery record after a disk failure must remain idempotent.
        try JSONEncoder().encode(pending).write(to: marker)
        store.resumePendingSignIn()
        for _ in 0..<100 {
            if store.signInState == nil { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(store.accounts.count, 1)
        XCTAssertEqual(browserOpens, 0)
    }
    @MainActor func testLiveDeviceHandshake() async throws {
        guard ProcessInfo.processInfo.environment["QUOTABAR_LIVE_AUTH_TEST"] == "1" else { throw XCTSkip("Opt-in live network check") }
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("quotabar-live-check-\(UUID())")
        let client = try CodexClient(home: home)
        defer { client.stop(); try? FileManager.default.removeItem(at: home) }
        try await client.start()
        let before = try await client.request("account/read", params: ["refreshToken": false])
        guard try JSONDecoder().decode(CodexIdentity.self, from: before).account == nil else {
            return XCTFail("The test profile is not isolated; refusing to modify its authentication.")
        }
        let data = try await client.request("account/login/start", params: ["type": "chatgptDeviceCode"])
        let login = try JSONDecoder().decode(DeviceSignIn.self, from: data)
        XCTAssertEqual(login.browserURL?.host, "auth.openai.com")
        XCTAssertFalse(login.userCode?.isEmpty ?? true)
        _ = try await client.request("account/login/cancel", params: ["loginId": login.loginId])
        _ = try await client.request("account/logout")
        let accountData = try await client.request("account/read", params: ["refreshToken": false])
        XCTAssertNil(try JSONDecoder().decode(CodexIdentity.self, from: accountData).account)
    }
}
