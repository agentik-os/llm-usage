import XCTest
@testable import OpenAIQuotaBar

final class LocalTests: XCTestCase {
    func testModelsCombineInstalledAndLoadedLargestFirst() throws {
        let tags = Data("""
        {"models":[
          {"name":"small:4b","size":3000000000,"details":{"parameter_size":"4B","quantization_level":"Q4_K_M"}},
          {"name":"large:120b","size":65000000000,"details":{"parameter_size":"120B","quantization_level":"Q4_K_M"}},
          {"name":"bare:1b"}
        ]}
        """.utf8)
        let running = Data(#"{"models":[{"name":"large:120b","size":70000000000,"size_vram":66000000000}]}"#.utf8)
        let models = try LocalParsing.models(tags: tags, running: running)
        XCTAssertEqual(models.map(\.name), ["large:120b", "small:4b", "bare:1b"])
        XCTAssertEqual(models[0].memoryBytes, 66_000_000_000)
        XCTAssertTrue(models[0].isLoaded)
        XCTAssertFalse(models[1].isLoaded)
        XCTAssertEqual(models[0].summary, "120B · Q4_K_M · 65 GB")
        XCTAssertEqual(models[1].summary, "4B · Q4_K_M · 3 GB")
        XCTAssertEqual(models[2].summary, "0 MB")
    }

    func testModelsWithoutRunningListAndEmptyServer() throws {
        let models = try LocalParsing.models(tags: Data(#"{"models":[{"name":"a:1b","size":900000000}]}"#.utf8), running: nil)
        XCTAssertEqual(models.count, 1)
        XCTAssertNil(models[0].memoryBytes)
        XCTAssertEqual(models[0].summary, "900 MB")
        XCTAssertEqual(try LocalParsing.models(tags: Data("{}".utf8), running: Data("not json".utf8)), [])
        XCTAssertThrowsError(try LocalParsing.models(tags: Data("not json".utf8), running: nil))
    }

    func testTokensPerSecondUsesNanosecondDurations() {
        let speed = LocalParsing.tokensPerSecond(generation: Data(#"{"eval_count":96,"eval_duration":2000000000}"#.utf8))
        XCTAssertEqual(speed ?? 0, 48, accuracy: 0.001)
        XCTAssertNil(LocalParsing.tokensPerSecond(generation: Data(#"{"eval_count":0,"eval_duration":2000000000}"#.utf8)))
        XCTAssertNil(LocalParsing.tokensPerSecond(generation: Data(#"{"eval_count":96}"#.utf8)))
        XCTAssertNil(LocalParsing.tokensPerSecond(generation: Data("oops".utf8)))
        XCTAssertEqual(LocalFormat.speed(48.4), "48")
        XCTAssertEqual(LocalFormat.speed(7.0), "7")
    }

    func testAgentSessionsAreCountedWithoutHelpersOrDaemons() {
        let processes = """
        claude
        /Users/someone/.local/bin/claude --dangerously-skip-permissions
        /Users/someone/.local/share/claude/versions/2.1.323 --session-id 00000000-0000-0000-0000-000000000000 --resume
        claude bg-spare --bg-spare /tmp/cc-daemon-501/x/spare/a.claim.sock
        /Users/someone/.local/share/claude/ClaudeCode.app/Contents/MacOS/claude --bg-pty-host /tmp/cc-daemon-501/x/pty/a.sock 218 63
        /Users/someone/.local/bin/claude daemon run --origin transient
        /Applications/Claude.app/Contents/MacOS/Claude
        /Applications/Claude.app/Contents/Frameworks/Claude Helper (Renderer).app/Contents/MacOS/Claude Helper (Renderer) --type=renderer
        /Users/someone/.local/bin/codex
        /Users/someone/.codex/packages/app-server-daemon/releases/0.169.0/bin/codex app-server --listen unix://
        /Users/someone/.hermes/tools/python/bin/python3 -m hermes_cli.main --profile default
        /bin/zsh /Users/someone/.local/bin/hermes-gateway-keepalive.sh
        /usr/bin/osascript -l JavaScript -e run /Users/someone/.hermes/tools/python/bin/python3 -m hermes_cli.main --profile default
        /opt/homebrew/bin/opencode
        /opt/homebrew/bin/opencode serve --port 4096
        /usr/bin/grep claude
        """
        let counts = LocalParsing.agentCounts(processList: processes)
        XCTAssertEqual(counts, [.claudeCode: 3, .codex: 1, .hermes: 1, .openCode: 1])
        XCTAssertEqual(LocalParsing.agentCounts(processList: ""), [:])
    }

    @MainActor func testPreviewMonitorShowsSamplesAndNeverTouchesTheServer() async {
        let monitor = LocalMonitor(preview: true, server: URL(string: "http://127.0.0.1:1")!)
        let before = monitor.models
        await monitor.refresh()
        await monitor.measure(before[0])
        XCTAssertEqual(monitor.models, before)
        XCTAssertTrue(monitor.serverReachable)
        XCTAssertNil(monitor.error)
        XCTAssertEqual(monitor.totalAgents, 6)
        XCTAssertTrue(before.contains { $0.isEmbedding })
    }

    @MainActor func testUnreachableServerIsReportedAndSavedSpeedsAreLoaded() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("quotabar-local-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("local-speeds.json")
        let saved = ["a:1b": ModelSpeed(tokensPerSecond: 12.5, measuredAt: Date(timeIntervalSince1970: 1_700_000_000))]
        try JSONEncoder().encode(saved).write(to: file)
        let monitor = LocalMonitor(server: URL(string: "http://127.0.0.1:1")!, speedsFile: file)
        XCTAssertEqual(monitor.speeds, saved)
        monitor.error = "Couldn’t measure a:1b."
        await monitor.refresh()
        XCTAssertFalse(monitor.serverReachable)
        XCTAssertEqual(monitor.models, [])
        XCTAssertEqual(monitor.error, "Couldn’t measure a:1b.", "Refreshing must keep the last measurement error visible")
    }
}
