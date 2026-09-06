import XCTest
@testable import OpenAIQuotaBar

final class SSHDiscoveryTests: XCTestCase {
    func testIncludesAliasesAndQuotedValuesWithoutExecutingConfiguration() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("llm-ssh-\(UUID())")
        let ssh = home.appendingPathComponent(".ssh")
        try FileManager.default.createDirectory(at: ssh.appendingPathComponent("hosts"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let sentinel = home.appendingPathComponent("must-not-exist")
        try """
        # Existing setup; no keys or commands should be evaluated.
        Host production prod
            HostName=prod.example.invalid
            User deploy
            Port 2222
            IdentityFile /never/read/this/key
            ProxyCommand touch \(sentinel.path)
        Host *.internal !excluded
            HostName not-a-concrete-host
        Include hosts/*.conf
        Include "with spaces.conf"
        Match exec "touch \(sentinel.path)"
            HostName must-not-be-used
        Host production
            HostName second-value-must-not-win
        Host -option $(command) user@not-an-alias
        """.write(to: ssh.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        try "Host worker\n HostName worker.example.invalid\nInclude config\n"
            .write(to: ssh.appendingPathComponent("hosts/worker.conf"), atomically: true, encoding: .utf8)
        try "hOsT \"staging\"\n HostName staging.example.invalid\n User \"test-user\" # trailing comment\n"
            .write(to: ssh.appendingPathComponent("with spaces.conf"), atomically: true, encoding: .utf8)
        let result = SSHHostDiscovery.scan(home: home, systemConfig: nil)
        XCTAssertEqual(result.hosts.map(\.alias), ["prod", "production", "staging", "worker"])
        XCTAssertEqual(result.hosts.first?.destination, "deploy@prod.example.invalid · port 2222")
        XCTAssertEqual(result.hosts.first(where: { $0.alias == "production" })?.hostname, "prod.example.invalid")
        XCTAssertEqual(result.hosts.first(where: { $0.alias == "staging" })?.user, "test-user")
        XCTAssertFalse(result.incomplete)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sentinel.path))
    }

    func testEmptySetupAndSystemAliasesRemainReadOnly() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("llm-ssh-empty-\(UUID())")
        XCTAssertTrue(SSHHostDiscovery.scan(home: home, systemConfig: nil).hosts.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.path))
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let system = home.appendingPathComponent("ssh_config")
        try "Host system-vps\n HostName 192.0.2.1\n".write(to: system, atomically: true, encoding: .utf8)
        XCTAssertEqual(SSHHostDiscovery.scan(home: home, systemConfig: system).hosts.map(\.alias), ["system-vps"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".ssh").path))
    }

    func testOversizedFilesAreSkippedAndTokenizationPreservesQuotes() throws {
        XCTAssertEqual(SSHHostDiscovery.tokens("Include = \"hosts/my file.conf\" # comment"), ["Include", "hosts/my file.conf"])
        XCTAssertEqual(SSHHostDiscovery.tokens("HostName \"host#name\""), ["HostName", "host#name"])
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("llm-ssh-limit-\(UUID())")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try String(repeating: "x", count: 1_000_001).write(to: home.appendingPathComponent(".ssh/config"), atomically: true, encoding: .utf8)
        let result = SSHHostDiscovery.scan(home: home, systemConfig: nil)
        XCTAssertTrue(result.incomplete)
        XCTAssertTrue(result.hosts.isEmpty)
    }
}
