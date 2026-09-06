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
            XCTAssertEqual(command, "status")
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
        XCTAssertEqual(pool.selections[vps.id]?.accountID, b.id)
        XCTAssertEqual(pool.confirmedCount, 0)
        XCTAssertTrue(pool.isSelected(a.id)); XCTAssertTrue(pool.isSelected(b.id))
        let restored = AccountPool(file: file)
        XCTAssertEqual(restored.selections, pool.selections)
        sent.removeAll(); offline = false
        await pool.synchronize()
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: sent), [PoolDevice.local.id: a.id.uuidString, vps.id: b.id.uuidString, other.id: a.id.uuidString])
        XCTAssertEqual(pool.confirmedCount, 3)
        XCTAssertEqual(pool.activeDevices(for: b.id).map(\.id), [vps.id])
        sent.removeAll()
        await pool.use(b, on: [PoolDevice.local.id])
        XCTAssertEqual(sent.map { $0.0 }, [PoolDevice.local.id])
        XCTAssertEqual(pool.selections[other.id]?.accountID, a.id)
        sent.removeAll()
        await pool.use(a, on: [])
        XCTAssertTrue(sent.isEmpty)
        await pool.use(b)
        XCTAssertEqual(Set(sent.map { $0.0 }), Set(pool.devices.map(\.id)))
        XCTAssertEqual(pool.confirmedCount, 3)
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
