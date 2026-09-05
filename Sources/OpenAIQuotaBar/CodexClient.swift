import Foundation

/// A private stdio connection to the supported Codex app-server protocol.
/// Authentication, usage and expiring access grants for connected devices.
@MainActor
final class CodexClient {
    var notification: ((String, Data) -> Void)?
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var buffer = Data()
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var timers: [Int: Task<Void, Never>] = [:]
    private var stopped = false

    static func executableURL() throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".local/bin/codex").path,
            home.appendingPathComponent(".codex/packages/standalone/current/bin/codex").path,
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex"
        ]
        guard let path = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw UsageError.message("Install Codex on this Mac, then try signing in again.")
        }
        return URL(fileURLWithPath: path)
    }

    static func environment(for home: URL, inherited: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = inherited
        for key in ["OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN", "OPENAI_BASE_URL", "CHATGPT_BASE_URL", "CODEX_HOME", "CODEX_MANAGED_BY_NPM", "CODEX_INTERNAL_ORIGINATOR_OVERRIDE"] {
            env.removeValue(forKey: key)
        }
        env["CODEX_HOME"] = home.path
        env["RUST_LOG"] = "error"
        return env
    }

    init(home: URL, executable: URL? = nil, prefixArguments: [String] = []) throws {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        process.executableURL = try executable ?? Self.executableURL()
        process.arguments = prefixArguments + ["-c", "cli_auth_credentials_store=\"keyring\"", "app-server", "--listen", "stdio://"]
        process.currentDirectoryURL = home
        process.environment = Self.environment(for: home)
        process.standardInput = input
        process.standardOutput = output
        // Auth payloads and tokens are never logged by this app.
        process.standardError = FileHandle.nullDevice
    }

    func start() async throws {
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in self?.receive(data) }
        }
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                // Give the final stdout response time to reach the main actor.
                try? await Task.sleep(nanoseconds: 50_000_000)
                self?.finishPending(UsageError.message("The OpenAI connection closed. Please try again."))
            }
        }
        do {
            try process.run()
            _ = try await request("initialize", params: ["clientInfo": ["name": "quotabar", "title": "LLM Usage", "version": "4.0.1"]])
            try send(["method": "initialized", "params": [:]])
        } catch { stop(); throw error }
    }

    func request(_ method: String, params: [String: Any]? = nil, timeout: Double = 35) async throws -> Data {
        let allowed: Set<String> = ["initialize", "account/login/start", "account/login/cancel", "account/read", "account/logout", "account/rateLimits/read", "account/usage/read", "getAuthStatus"]
        guard allowed.contains(method) else { throw UsageError.message("Unsupported account operation.") }
        try Task.checkCancellation()
        guard !stopped, process.isRunning else { throw UsageError.message("The OpenAI connection is not running.") }
        nextID += 1
        let id = nextID
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                timers[id] = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: UInt64(max(timeout, 0.01) * 1_000_000_000)) }
                    catch { return }
                    self?.resolve(id, .failure(UsageError.message("OpenAI took too long to respond. Please try again.")))
                }
                var message: [String: Any] = ["id": id, "method": method]
                if let params { message["params"] = params }
                do { try send(message) } catch { resolve(id, .failure(error)) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resolve(id, .failure(CancellationError())) }
        }
    }

    private func send(_ message: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(0x0A)
        try input.fileHandleForWriting.write(contentsOf: data)
    }
    private func receive(_ data: Data) {
        guard !stopped else { return }
        buffer.append(data)
        guard buffer.count < 8_000_000 else { stop(); return }
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if let method = message["method"] as? String {
                if let id = message["id"] {
                    // This usage-only client never grants tool or other server-initiated requests.
                    try? send(["id": id, "error": ["code": -32601, "message": "Not supported by LLM Usage"]])
                } else if let data = try? JSONSerialization.data(withJSONObject: message["params"] ?? [:]) {
                    notification?(method, data)
                }
            } else if let id = message["id"] as? Int {
                if let error = message["error"] as? [String: Any] {
                    let detail = error["message"] as? String ?? "OpenAI couldn’t complete the request."
                    // Avoid exposing arbitrary response bodies, URLs or credentials in the UI.
                    let safe = detail.lowercased().contains("device") ? "Device sign-in is unavailable. Try browser sign-in instead." :
                        detail.lowercased().contains("auth") || detail.lowercased().contains("login") ? "Please sign in again to refresh this account." :
                        "OpenAI couldn’t complete the request. Please try again."
                    resolve(id, .failure(UsageError.message(safe)))
                } else if let result = message["result"], let data = try? JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed]) {
                    resolve(id, .success(data))
                }
            }
        }
    }
    private func resolve(_ id: Int, _ result: Result<Data, Error>) {
        timers.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(with: result)
    }
    private func finishPending(_ error: Error) {
        for id in Array(pending.keys) { resolve(id, .failure(error)) }
    }
    func stop() {
        guard !stopped else { return }
        stopped = true
        output.fileHandleForReading.readabilityHandler = nil
        notification = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        finishPending(CancellationError())
    }
}

struct DeviceSignIn: Decodable, Equatable {
    let type: String
    let loginId: String
    let verificationUrl: String?
    let userCode: String?
    let authUrl: String?
    var browserURL: URL? {
        guard let value = verificationUrl ?? authUrl, let url = URL(string: value), url.scheme == "https",
              ["auth.openai.com", "chatgpt.com"].contains(url.host?.lowercased() ?? ""), url.user == nil, url.password == nil else { return nil }
        return url
    }
}

struct LoginCompletion: Decodable { let loginId: String?; let success: Bool; let error: String? }
struct CodexIdentity: Decodable {
    struct Details: Decodable { let type: String; let email: String?; let planType: String? }
    let account: Details?
}
enum SignInState: Equatable {
    case starting
    case waiting(DeviceSignIn)
    case completing
    case failed(String)
}
