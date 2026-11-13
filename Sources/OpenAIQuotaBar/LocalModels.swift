import Combine
import Foundation

/// A model installed in the local Ollama server.
struct LocalModel: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let sizeBytes: Int64
    var parameters: String?
    var quantization: String?
    /// Set when the model is currently loaded in memory.
    var memoryBytes: Int64?
    var isLoaded: Bool { memoryBytes != nil }
    /// Embedding models don't generate text, so they have no generation speed.
    var isEmbedding: Bool { name.lowercased().contains("embed") }

    var summary: String {
        ([parameters, quantization].compactMap { $0?.isEmpty == false ? $0 : nil } + [LocalFormat.bytes(sizeBytes)])
            .joined(separator: " · ")
    }
}

struct ModelSpeed: Codable, Equatable {
    var tokensPerSecond: Double
    var measuredAt: Date
}

/// Coding agents whose running sessions are counted on this Mac.
enum AgentKind: String, CaseIterable, Identifiable {
    case claudeCode = "Claude Code"
    case codex = "Codex"
    case hermes = "Hermes"
    case openCode = "OpenCode"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .claudeCode: "sparkle"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .hermes: "bolt.horizontal"
        case .openCode: "terminal"
        }
    }
}

enum LocalFormat {
    static func bytes(_ value: Int64) -> String {
        let gigabytes = Double(value) / 1_000_000_000
        if gigabytes >= 10 { return "\(Int(gigabytes.rounded())) GB" }
        if gigabytes >= 1 { return gigabytes.formatted(.number.precision(.fractionLength(0...1))) + " GB" }
        return "\(Int((Double(value) / 1_000_000).rounded())) MB"
    }
    static func speed(_ tokensPerSecond: Double) -> String {
        tokensPerSecond >= 10 ? "\(Int(tokensPerSecond.rounded()))" : tokensPerSecond.formatted(.number.precision(.fractionLength(0...1)))
    }
}

enum LocalParsing {
    private struct Listing: Decodable {
        struct Model: Decodable {
            struct Details: Decodable { var parameter_size: String?; var quantization_level: String? }
            var name: String
            var size: Int64?
            var size_vram: Int64?
            var details: Details?
        }
        var models: [Model]?
    }
    private struct Generation: Decodable { var eval_count: Double?; var eval_duration: Double? }

    /// Combines Ollama's `/api/tags` (installed) and `/api/ps` (in memory) responses.
    static func models(tags: Data, running: Data?) throws -> [LocalModel] {
        let installed = try JSONDecoder().decode(Listing.self, from: tags).models ?? []
        let loaded = running.flatMap { try? JSONDecoder().decode(Listing.self, from: $0).models } ?? []
        let memory = Dictionary(loaded.map { ($0.name, $0.size_vram ?? $0.size ?? 0) }, uniquingKeysWith: { first, _ in first })
        return installed.map {
            LocalModel(name: $0.name, sizeBytes: $0.size ?? 0, parameters: $0.details?.parameter_size,
                       quantization: $0.details?.quantization_level, memoryBytes: memory[$0.name])
        }.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    /// Generation speed from an Ollama `/api/generate` response; durations are in nanoseconds.
    static func tokensPerSecond(generation: Data) -> Double? {
        guard let result = try? JSONDecoder().decode(Generation.self, from: generation),
              let count = result.eval_count, let duration = result.eval_duration, count > 0, duration > 0 else { return nil }
        return count / (duration / 1_000_000_000)
    }

    /// Classifies one `ps` command line. Helper and daemon processes are not sessions.
    static func agentKind(commandLine: String) -> AgentKind? {
        let parts = commandLine.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let executable = parts.first else { return nil }
        let name = (executable as NSString).lastPathComponent
        let arguments = parts.dropFirst()
        // Wrappers that launch Hermes repeat its command line; only the interpreter is the session.
        if name.hasPrefix("python"), arguments.contains("hermes_cli.main") { return .hermes }
        if name == "claude" || executable.contains("/claude/versions/") {
            let helper = arguments.contains { $0 == "daemon" || $0.hasPrefix("bg-") || $0.hasPrefix("--bg-") }
            return helper ? nil : .claudeCode
        }
        if name == "codex" { return arguments.first == "app-server" ? nil : .codex }
        if name == "opencode" { return .openCode }
        return nil
    }

    static func agentCounts(processList: String) -> [AgentKind: Int] {
        var counts: [AgentKind: Int] = [:]
        for line in processList.split(whereSeparator: \.isNewline) {
            if let kind = agentKind(commandLine: String(line)) { counts[kind, default: 0] += 1 }
        }
        return counts
    }
}

/// Reads the local Ollama server and the running agent sessions on this Mac.
@MainActor
final class LocalMonitor: ObservableObject {
    @Published private(set) var models: [LocalModel] = []
    @Published private(set) var agents: [AgentKind: Int] = [:]
    @Published private(set) var speeds: [String: ModelSpeed] = [:]
    @Published private(set) var measuring: String?
    @Published private(set) var loading = false
    @Published private(set) var serverReachable = true
    @Published var error: String?

    let preview: Bool
    private let server: URL
    private let speedsFile: URL
    private let session: URLSession

    init(preview: Bool = false, server: URL = URL(string: "http://127.0.0.1:11434")!, speedsFile: URL? = nil, session: URLSession = .shared) {
        self.preview = preview
        self.server = server
        self.session = session
        self.speedsFile = speedsFile ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenAIQuotaBar/local-speeds.json")
        if preview {
            models = [
                LocalModel(name: "sample-large:120b", sizeBytes: 65_000_000_000, parameters: "120B", quantization: "Q4_K_M", memoryBytes: 66_000_000_000),
                LocalModel(name: "sample-coder:30b", sizeBytes: 18_000_000_000, parameters: "30.5B", quantization: "Q4_K_M"),
                LocalModel(name: "sample-embedding:4b", sizeBytes: 2_500_000_000, parameters: "4B", quantization: "Q4_K_M")
            ]
            agents = [.claudeCode: 4, .codex: 1, .hermes: 1]
            speeds = ["sample-large:120b": ModelSpeed(tokensPerSecond: 41.6, measuredAt: Date().addingTimeInterval(-900)),
                      "sample-coder:30b": ModelSpeed(tokensPerSecond: 96.2, measuredAt: Date().addingTimeInterval(-3600))]
        } else if let data = try? Data(contentsOf: self.speedsFile),
                  let saved = try? JSONDecoder().decode([String: ModelSpeed].self, from: data) {
            speeds = saved
        }
    }

    var totalAgents: Int { agents.values.reduce(0, +) }

    func refresh() async {
        guard !preview, !loading else { return }
        loading = true
        defer { loading = false }
        async let processes = Self.processList()
        do {
            let tags = try await data("api/tags", timeout: 5)
            let running = try? await data("api/ps", timeout: 5)
            models = try LocalParsing.models(tags: tags, running: running)
            serverReachable = true
            error = nil
        } catch {
            models = []
            serverReachable = false
        }
        agents = LocalParsing.agentCounts(processList: await processes)
    }

    /// Runs one short generation and records how fast the model answered.
    func measure(_ model: LocalModel) async {
        guard !preview, measuring == nil else { return }
        measuring = model.name
        defer { measuring = nil }
        do {
            let body: [String: Any] = ["model": model.name, "prompt": "Write a short paragraph about the sea.",
                                       "stream": false, "options": ["num_predict": 96]]
            let response = try await data("api/generate", body: JSONSerialization.data(withJSONObject: body), timeout: 900)
            guard let speed = LocalParsing.tokensPerSecond(generation: response) else {
                error = "\(model.name) answered without timing data."
                return
            }
            speeds[model.name] = ModelSpeed(tokensPerSecond: speed, measuredAt: Date())
            error = nil
            try? FileManager.default.createDirectory(at: speedsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(speeds).write(to: speedsFile, options: .atomic)
        } catch {
            self.error = "Couldn’t measure \(model.name). Check that Ollama is running and the model fits in memory."
        }
        await refresh()
    }

    private func data(_ path: String, body: Data? = nil, timeout: TimeInterval) async throws -> Data {
        var request = URLRequest(url: server.appendingPathComponent(path), timeoutInterval: timeout)
        if let body {
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    private nonisolated static func processList() async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                let pipe = Pipe()
                process.executableURL = URL(fileURLWithPath: "/bin/ps")
                process.arguments = ["-axo", "args="]
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                guard (try? process.run()) != nil else { return continuation.resume(returning: "") }
                let output = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: String(decoding: output, as: UTF8.self))
            }
        }
    }
}
