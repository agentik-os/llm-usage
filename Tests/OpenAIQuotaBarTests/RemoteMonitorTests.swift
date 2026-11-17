import XCTest
@testable import OpenAIQuotaBar

final class RemoteMonitorTests: XCTestCase {
    private var root: URL!
    private let sample = Data(#"{"version":1,"hostname":"fixture","platform":"Darwin","collectedAt":1800000000,"agents":{"codex":2,"claude":1},"models":[],"usage":[{"provider":"codex","tokens24h":100,"tokens7d":200,"input7d":180,"output7d":20,"cached7d":100,"sessions7d":2}],"partial":false,"sources":{"codex":true,"claude":false}}"#.utf8)
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("monitor-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    private func seed() throws -> MonitoredMachine {
        let machine = MonitoredMachine(name: "Fixture", sshHost: "test@fixture.example")
        try JSONEncoder().encode([machine]).write(to: root.appendingPathComponent("monitored-machines.json"))
        return machine
    }
    @MainActor func testReadOnlyTransportCachesUsageAndKeepsLastReadingOnFailure() async throws {
        let machine = try seed()
        var fail = false
        let monitor = RemoteMonitor(file: root.appendingPathComponent("monitored-machines.json"), transport: { host, script in
            XCTAssertEqual(host, machine.sshHost)
            if fail { throw CancellationError() }
            return self.sample
        })
        await monitor.refreshAll()
        XCTAssertEqual(monitor.observations[machine.id]?.usage.first?.tokens24h,100)
        fail = true
        await monitor.refreshAll()
        XCTAssertEqual(monitor.observations[machine.id]?.usage.first?.tokens24h,100)
        XCTAssertNotNil(monitor.errors[machine.id])
        let restored = RemoteMonitor(file: root.appendingPathComponent("monitored-machines.json"))
        XCTAssertEqual(restored.observations[machine.id], monitor.observations[machine.id])
    }
    @MainActor func testRemovedMachineIsNotRestoredByLateNetworkReply() async throws {
        let machine = try seed()
        var reply: CheckedContinuation<Data, Error>?
        let monitor = RemoteMonitor(file: root.appendingPathComponent("monitored-machines.json"), transport: { _, _ in
            try await withCheckedThrowingContinuation { reply = $0 }
        })
        let task = Task { await monitor.refresh(machine) }
        for _ in 0..<100 where reply == nil { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertNotNil(reply)
        try monitor.remove(machine)
        reply?.resume(returning: sample)
        await task.value
        XCTAssertTrue(monitor.machines.isEmpty)
        XCTAssertTrue(monitor.observations.isEmpty)
    }
    @MainActor func testMonitoringNeverAddsAccountSharingTargets() throws {
        let store = Store(ephemeral: true)
        try store.remoteMonitor.add(name: "Studio", host: "monitor@studio.example")
        XCTAssertEqual(store.remoteMonitor.machines.count, 1)
        XCTAssertEqual(store.pool.devices, [.local])
        XCTAssertTrue(store.pool.selections.isEmpty)
        for host in ["-oProxyCommand=evil", "user@host\ncommand", "host;command"] {
            XCTAssertThrowsError(try store.remoteMonitor.add(name: "Invalid", host: host))
        }
        XCTAssertThrowsError(try store.remoteMonitor.add(name: "Duplicate", host: "monitor@studio.example"))
    }
    @MainActor func testCorruptMachineListIsPreserved() throws {
        let file = root.appendingPathComponent("monitored-machines.json")
        try Data("{broken".utf8).write(to: file)
        let monitor = RemoteMonitor(file: file)
        XCTAssertNotNil(monitor.storageError)
        XCTAssertThrowsError(try monitor.add(name: "Studio", host: "studio.example"))
        XCTAssertEqual(try String(contentsOf: file), "{broken")
    }
    func testRemoteAccountsSeparateQuotaPercentagesFromRecordedTokens() throws {
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: sample) as? [String: Any])
        document["accounts"] = [["id": "claude-default", "provider": "claude", "profile": "Default Claude Code",
            "isDefault": true, "status": "connected", "email": "fixture@example.com", "plan": "default_claude_max_20x",
            "checkedAt": 1800000000, "windows": [["name": "Weekly", "remainingPercent": 37.5, "resetsAt": 1800100000]]]]
        let observation = try JSONDecoder().decode(MachineObservation.self, from: JSONSerialization.data(withJSONObject: document))
        let account = try XCTUnwrap(observation.accounts?.first)
        XCTAssertEqual(account.identityLabel, "fixture@example.com")
        XCTAssertEqual(account.planLabel, "Max 20X")
        XCTAssertEqual(account.windows.first?.fraction, 0.375)
        XCTAssertEqual(observation.usage.first?.tokens24h, 100)
        XCTAssertNil(try JSONDecoder().decode(MachineObservation.self, from: sample).accounts)
    }
}
