import XCTest
@testable import OpenAIQuotaBar

final class PoolTests: XCTestCase {
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
}
