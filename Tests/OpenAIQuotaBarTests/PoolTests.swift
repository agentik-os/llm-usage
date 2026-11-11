import XCTest
@testable import OpenAIQuotaBar

final class PoolTests: XCTestCase {
    @MainActor func testRemovingOfflineVPSPersistsAndStopsFutureSyncWithoutRemoteCommands() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("llm-remove-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("pool.json")
        let vps = PoolDevice(name: "Fixture VPS", sshHost: "fixture")
        let account = Account.samples[0]
        try JSONSerialization.data(withJSONObject: ["accountID": account.id.uuidString, "selectionID": "fixture",
            "devices": [["id": vps.id.uuidString, "name": vps.name, "sshHost": vps.sshHost]]]).write(to: file)
        let pool = AccountPool(file: file)
        pool.transport = { _, _, _ in XCTFail("Removal must never run a remote command"); throw CancellationError() }
        pool.remove(vps)
        XCTAssertEqual(pool.devices, [.local])
        XCTAssertNil(pool.selections[vps.id])
        XCTAssertNil(pool.connections[vps.id])
        XCTAssertEqual(pool.accountID, account.id)
        let restored = AccountPool(file: file)
        XCTAssertEqual(restored.devices, [.local])
        XCTAssertNil(restored.selections[vps.id])
        restored.remove(.local)
        XCTAssertEqual(restored.devices, [.local])
        restored.transport = { device, command, _ in
            XCTAssertTrue(device.isLocal, "Removed VPS must never be polled or switched")
            XCTAssertTrue(["status", "verify-switch"].contains(command))
            return Data("{\"ok\":true,\"result\":{\"state\":\"ready\"}}".utf8)
        }
        await restored.synchronize()
    }

    @MainActor func testRemovedPreviewVPSCanBeAddedAgain() async {
        let pool = AccountPool(preview: true)
        await pool.connect(name: "Fixture", host: "fixture")
        let vps = pool.devices.last!
        await pool.use(Account.samples[0], on: [vps.id])
        pool.remove(vps)
        XCTAssertFalse(pool.isInUse(Account.samples[0].id))
        await pool.connect(name: "Fixture", host: "fixture")
        XCTAssertEqual(pool.devices.count, 2)
        XCTAssertNotEqual(pool.devices.last?.id, vps.id)
        XCTAssertEqual(pool.devices.last?.sshHost, "fixture")
    }

    func token(_ claims: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: claims)
        return "test." + data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") + ".test"
    }

    func testGrantUsesAccountIdentityAndExpiryFromToken() throws {
        let account = Account.samples[0]
        let jwt = try token(["exp": Date().timeIntervalSince1970 + 3600,
                             "https://api.openai.com/auth": ["chatgpt_account_id": "workspace-1"]])
        let grant = try PoolGrant.make(account: account, selectionID: "selection", token: jwt)
        XCTAssertEqual(grant.chatgptAccountId, "workspace-1")
        XCTAssertEqual(grant.accountID, account.id.uuidString)
        XCTAssertEqual(grant.selectionID, "selection")
        XCTAssertThrowsError(try PoolGrant.make(account: account, selectionID: "s", token: "garbage"))
        XCTAssertThrowsError(try PoolGrant.make(account: account, selectionID: "s", token: token([
            "exp": Date().timeIntervalSince1970 - 10, "https://api.openai.com/auth": ["chatgpt_account_id": "w"]])))
        XCTAssertThrowsError(try PoolGrant.make(account: account, selectionID: "s", token: token(["exp": Date().timeIntervalSince1970 + 3600])))
    }

    func testGrantRefreshesBeforeExpiryAndRejectsChangedWorkspace() throws {
        let claims: [String: Any] = ["exp": Date().timeIntervalSince1970 + 120,
                                   "https://api.openai.com/auth": ["chatgpt_account_id": "workspace-1"]]
        XCTAssertTrue(PoolGrant.needsRefresh(try token(claims)))
        XCTAssertTrue(PoolGrant.needsRefresh("invalid"))
        XCTAssertFalse(PoolGrant.needsRefresh(try token(["exp": Date().timeIntervalSince1970 + 3600])))
        var account = Account.samples[0]
        account.codexUsage?.accountId = "different-workspace"
        XCTAssertThrowsError(try PoolGrant.make(account: account, selectionID: "hermes-local", token: token(claims)))
    }

    @MainActor func testRoutingGrantRenewsThroughItsOwnCodexProfile() async throws {
        for behavior in ["--grant-fresh", "--grant-expiring", "--grant-wrong-account"] {
            let home = FileManager.default.temporaryDirectory.appendingPathComponent("llm-hermes-grant-\(UUID())")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: home) }
            var account = Account.samples[0]
            account.authSessionID = UUID()
            account.codexUsage?.accountId = "fixture-workspace"
            let file = home.appendingPathComponent("accounts.json")
            try JSONEncoder().encode([account]).write(to: file)
            let fixture = Bundle.module.url(forResource: "fake-codex", withExtension: "py", subdirectory: "Fixtures")!
            let store = Store(accountsFile: file, makeClient: {
                try CodexClient(home: $0, executable: URL(fileURLWithPath: "/usr/bin/python3"), prefixArguments: [fixture.path, behavior])
            })
            defer { store.shutdown() }
            do {
                let grant = try await store.routingGrant(account.id, selectionID: "hermes-local")
                XCTAssertNotEqual(behavior, "--grant-wrong-account")
                XCTAssertEqual(grant.chatgptAccountId, "fixture-workspace")
                XCTAssertFalse(PoolGrant.needsRefresh(grant.accessToken))
            } catch {
                XCTAssertEqual(behavior, "--grant-wrong-account")
            }
            let profile = home.appendingPathComponent("Sessions").appendingPathComponent(account.authSessionID!.uuidString)
            let requests = try JSONDecoder().decode([Bool].self, from: Data(contentsOf: profile.appendingPathComponent("grant-refresh-requests.json")))
            XCTAssertEqual(requests, behavior == "--grant-expiring" ? [false, true] : [false])
        }
    }

    @MainActor func testSSHInputCannotBecomeAnOptionOrShellCommand() {
        for host in ["my-vps", "user@my-server", "user@10.0.0.1"] { XCTAssertTrue(AccountPool.validSSHHost(host)) }
        for host in ["", "-oProxyCommand=evil", "host;touch /tmp/evil", "host\nwhoami", "$(whoami)", "`whoami`", "host space", "host/../../"] {
            XCTAssertFalse(AccountPool.validSSHHost(host))
        }
    }

    @MainActor func testPreviewSwitchIsEphemeralAndProtectsActiveAccount() async throws {
        let store = Store(ephemeral: true)
        let a = Account.samples[0], b = Account.samples[1]
        try store.saveAccount(a, key: "")
        try store.saveAccount(b, key: "")
        await store.pool.use(a)
        XCTAssertEqual(store.pool.accountID, a.id)
        XCTAssertEqual(store.pool.confirmedCount, 1)
        do { try await store.disconnect(a); XCTFail("Active account must remain connected") }
        catch { XCTAssertEqual(store.accounts.count, 2) }
        await store.pool.use(b)
        try await store.disconnect(a)
        XCTAssertEqual(store.accounts.map(\.id), [b.id])
        XCTAssertEqual(store.pool.accountID, b.id)
    }

    @MainActor func testTargetedSwitchPersistsAndRetriesOnlyEachDevicesOwnAccount() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("llm-targets-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("pool.json")
        let vps = PoolDevice(name: "VPS", sshHost: "fixture-vps")
        let other = PoolDevice(name: "Other VPS", sshHost: "fixture-other")
        struct Legacy: Encodable { let accountID: UUID; let selectionID: String; let devices: [PoolDevice] }
        let a = Account.samples[0], b = Account.samples[1]
        try JSONEncoder().encode(Legacy(accountID: a.id, selectionID: "old", devices: [vps, other])).write(to: file)
        let pool = AccountPool(file: file)
        XCTAssertEqual(pool.selections.count, 3, "Legacy global choice migrates to all existing devices")
        var sent: [(UUID, String)] = []
        var offline = true
        pool.grantProvider = { id, selection in
            PoolGrant(selectionID: selection, accountID: id.uuidString, name: "Fixture", accessToken: "fake", chatgptAccountId: "fake", planType: "pro")
        }
        pool.transport = { device, command, data in
            if command == "verify-switch" {
                let choice = try JSONDecoder().decode(DeviceSelection.self, from: XCTUnwrap(data))
                return try self.verification(choice, supported: false)
            }
            XCTAssertEqual(command, "rpc")
            let request = try JSONSerialization.jsonObject(with: XCTUnwrap(data)) as! [String: Any]
            let grant = request["grant"] as! [String: Any]
            sent.append((device.id, grant["accountID"] as! String))
            if device.id == vps.id && offline { throw CancellationError() }
            return try JSONSerialization.data(withJSONObject: ["ok": true, "result": [
                "accountID": grant["accountID"]!, "selectionID": grant["selectionID"]!, "state": "active", "codexConnected": true]])
        }
        await pool.use(b, on: [vps.id])
        XCTAssertEqual(sent.map { $0.0 }, [vps.id], "A VPS-only switch must never contact this Mac or another VPS")
        XCTAssertEqual(pool.accountID, a.id)
        XCTAssertTrue(pool.showingDevices, "Show the actual switch result after a click")
        XCTAssertEqual(pool.selections[vps.id]?.accountID, b.id)
        XCTAssertEqual(pool.confirmedCount, 0)
        XCTAssertTrue(pool.isSelected(a.id)); XCTAssertTrue(pool.isSelected(b.id))
        let restored = AccountPool(file: file)
        XCTAssertEqual(restored.selections, pool.selections)
        sent.removeAll(); offline = false
        await pool.synchronize()
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: sent), [PoolDevice.local.id: a.id.uuidString, vps.id: b.id.uuidString, other.id: a.id.uuidString])
        XCTAssertEqual(pool.confirmedCount, 0, "Token selection on an old server must never count as a completed switch")
        XCTAssertTrue(pool.isConnectionSelected(vps))
        XCTAssertTrue(pool.activeDevices(for: b.id).isEmpty)
        XCTAssertEqual(pool.connections[vps.id]?.compatibility?.restartRequired, true)
        XCTAssertNotNil(pool.connections[vps.id]?.compatibility?.message)

        sent.removeAll()
        await pool.use(b, on: [PoolDevice.local.id])
        XCTAssertEqual(sent.map { $0.0 }, [PoolDevice.local.id])
        XCTAssertEqual(pool.selections[other.id]?.accountID, a.id)
        sent.removeAll()
        await pool.use(a, on: [])
        XCTAssertTrue(sent.isEmpty)
        await pool.use(b)
        XCTAssertEqual(Set(sent.map { $0.0 }), Set(pool.devices.map(\.id)))
        XCTAssertEqual(pool.confirmedCount, 0)
    }

    func verification(_ choice: DeviceSelection, supported: Bool = true, backend: Bool = true,
                      other: Int = 0, checkedAt: Double = Date().timeIntervalSince1970) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["ok": true, "result": [
            "accountID": choice.accountID.uuidString, "selectionID": choice.selectionID,
            "credentialConfirmed": true, "backendVerified": backend,
            "runningVersion": supported ? "0.155.1" : "0.153.4", "installedVersion": "0.155.1",
            "liveSwitchSupported": supported, "restartRequired": !supported,
            "coverageKnown": true, "otherTerminals": other, "sharedTerminals": 3,
            "standaloneAgkSessions": 0, "checkedAt": checkedAt]])
    }

    @MainActor func testSwitchRequiresFreshMatchingBackendVerificationAndNoSeparateTerminals() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("llm-verify-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let pool = AccountPool(file: dir.appendingPathComponent("pool.json"))
        pool.grantProvider = { id, selection in
            PoolGrant(selectionID: selection, accountID: id.uuidString, name: "Fixture", accessToken: "fake", chatgptAccountId: "fake", planType: "pro")
        }
        var state = "ready"
        pool.transport = { _, command, input in
            if command == "verify-switch" {
                let choice = try JSONDecoder().decode(DeviceSelection.self, from: XCTUnwrap(input))
                if state == "unavailable" { throw CancellationError() }
                return try self.verification(state == "mismatch" ? DeviceSelection(accountID: UUID(), selectionID: "other") : choice,
                    backend: state != "rejected", other: state == "separate" ? 1 : 0,
                    checkedAt: Date().timeIntervalSince1970 - (state == "stale" ? 100 : 0))
            }
            let request = try JSONSerialization.jsonObject(with: XCTUnwrap(input)) as! [String: Any]
            let grant = request["grant"] as! [String: Any]
            return try JSONSerialization.data(withJSONObject: ["ok": true, "result": [
                "accountID": grant["accountID"]!, "selectionID": grant["selectionID"]!, "state": "active", "codexConnected": true]])
        }
        await pool.use(Account.samples[0])
        XCTAssertEqual(pool.confirmedCount, 1)
        for failure in ["rejected", "separate", "stale", "unavailable", "mismatch"] {
            state = failure
            await pool.retry(.local)
            XCTAssertEqual(pool.confirmedCount, 0, failure)
            XCTAssertTrue(pool.isConnectionSelected(.local), "Preserve selection, distinguish failed verification")
        }
        state = "ready"
        await pool.retryPending()
        XCTAssertEqual(pool.confirmedCount, 1)
        XCTAssertEqual(AccountPool(file: dir.appendingPathComponent("pool.json")).selections, pool.selections)
    }

    @MainActor func testOfflineDeviceDoesNotBlockOthersAndRetrySkipsConfirmedDevices() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("llm-concurrent-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("pool.json")
        let remote = PoolDevice(name: "Offline", sshHost: "fixture")
        try JSONSerialization.data(withJSONObject: ["devices": [["id": remote.id.uuidString, "name": remote.name, "sshHost": remote.sshHost]]]).write(to: file)
        let pool = AccountPool(file: file)
        var grantReads = 0, localConfirmedWhileRemoteWaited = false, contacted: [UUID] = []
        pool.grantProvider = { id, selection in
            grantReads += 1
            return PoolGrant(selectionID: selection, accountID: id.uuidString, name: "Fixture", accessToken: "fake", chatgptAccountId: "fake", planType: "pro")
        }
        pool.transport = { device, command, input in
            if command == "verify-switch" {
                return try self.verification(JSONDecoder().decode(DeviceSelection.self, from: XCTUnwrap(input)))
            }
            contacted.append(device.id)
            if !device.isLocal {
                try await Task.sleep(nanoseconds: 100_000_000)
                localConfirmedWhileRemoteWaited = pool.isConfirmed(.local)
                throw CancellationError()
            }
            let request = try JSONSerialization.jsonObject(with: XCTUnwrap(input)) as! [String: Any]
            let grant = request["grant"] as! [String: Any]
            return try JSONSerialization.data(withJSONObject: ["ok": true, "result": [
                "accountID": grant["accountID"]!, "selectionID": grant["selectionID"]!, "state": "active", "codexConnected": true]])
        }
        await pool.use(Account.samples[0])
        XCTAssertTrue(localConfirmedWhileRemoteWaited)
        XCTAssertEqual(pool.confirmedCount, 1)
        contacted.removeAll()
        await pool.retryPending()
        XCTAssertEqual(contacted, [remote.id])
        grantReads = 0
        await pool.synchronize()
        XCTAssertEqual(grantReads, 1, "Renew one account once even when several devices use it")
    }

    @MainActor func testRemoteSelectedAccountCannotBeDisconnectedAndPreviewNeverContactsCodex() async throws {
        let store = Store(ephemeral: true)
        let a = Account.samples[0], b = Account.samples[1]
        try store.saveAccount(a, key: ""); try store.saveAccount(b, key: "")
        await store.pool.connect(name: "Fixture VPS", host: "fixture")
        let vps = try XCTUnwrap(store.pool.devices.last)
        store.pool.transport = { _, _, _ in XCTFail("Preview must never run real commands"); throw CancellationError() }
        await store.pool.use(a, on: [vps.id])
        await store.pool.use(b, on: [PoolDevice.local.id])
        do { try await store.disconnect(a); XCTFail("Remote account must remain connected") } catch { }
        _ = try await store.pool.runtimeSettings(for: vps)
        let result = try await store.pool.runtimeSettings(for: vps, version: "preview", changes: ["sandbox": "danger-full-access", "approval": "never"])
        XCTAssertEqual(result.approval, "never")
        let local = try await store.pool.runtimeSettings(for: .local)
        XCTAssertEqual(local.sandbox, "workspace-write")
    }
}
