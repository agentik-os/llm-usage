import Foundation
import CryptoKit

/// Claude subscription usage, expressed with the same window shape as Codex so
/// both providers share the gauge, rows and reset labels.
struct ClaudeUsage: Codable, Equatable {
    struct ScopedWindow: Codable, Equatable {
        var name: String
        var window: CodexUsage.Window
    }
    var session: CodexUsage.Window?
    var weekly: CodexUsage.Window?
    var scoped: [ScopedWindow] = []

    /// The window that limits usage right now: the one with the least remaining.
    /// Claude omits the 5-hour window once the weekly limit is exhausted.
    var binding: CodexUsage.Window? {
        guard let session, let weekly else { return session ?? weekly }
        return weekly.remainingPercent < session.remainingPercent ? weekly : session
    }
    var other: CodexUsage.Window? {
        guard let session, let weekly else { return nil }
        return binding == weekly ? session : weekly
    }

    /// Response of `GET https://api.anthropic.com/api/oauth/usage` (the source Claude Code's `/usage` reads).
    struct Response: Decodable {
        struct Bucket: Decodable { let utilization: Double?; let resets_at: String? }
        struct Limit: Decodable {
            struct Scope: Decodable {
                struct Model: Decodable { let display_name: String? }
                let model: Model?
            }
            let kind: String?
            let percent: Double?
            let resets_at: String?
            let scope: Scope?
        }
        let five_hour: Bucket?
        let seven_day: Bucket?
        let seven_day_opus: Bucket?
        let seven_day_sonnet: Bucket?
        let limits: [Limit]?
    }

    init(session: CodexUsage.Window? = nil, weekly: CodexUsage.Window? = nil, scoped: [ScopedWindow] = []) {
        self.session = session
        self.weekly = weekly
        self.scoped = scoped
    }

    init(_ response: Response) {
        session = Self.window(response.five_hour?.utilization, response.five_hour?.resets_at, minutes: 300)
        weekly = Self.window(response.seven_day?.utilization, response.seven_day?.resets_at, minutes: 10080)
        var scoped: [ScopedWindow] = []
        for limit in response.limits ?? [] where limit.kind == "weekly_scoped" {
            guard let name = limit.scope?.model?.display_name, !name.isEmpty,
                  let window = Self.window(limit.percent, limit.resets_at, minutes: 10080) else { continue }
            scoped.append(ScopedWindow(name: name, window: window))
        }
        if scoped.isEmpty {
            // Older responses expose per-model weekly buckets as top-level keys.
            if let opus = Self.window(response.seven_day_opus?.utilization, response.seven_day_opus?.resets_at, minutes: 10080) { scoped.append(.init(name: "Opus", window: opus)) }
            if let sonnet = Self.window(response.seven_day_sonnet?.utilization, response.seven_day_sonnet?.resets_at, minutes: 10080) { scoped.append(.init(name: "Sonnet", window: sonnet)) }
        }
        self.scoped = scoped
    }

    static func window(_ percent: Double?, _ reset: String?, minutes: Int) -> CodexUsage.Window? {
        guard let percent, percent.isFinite else { return nil }
        return CodexUsage.Window(usedPercent: Int(percent.rounded()), windowDurationMins: minutes,
                                 resetsAt: reset.flatMap(parseDate).map { Int($0.timeIntervalSince1970) })
    }

    static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

struct ClaudeProfile: Decodable, Equatable {
    struct AccountInfo: Decodable, Equatable { let email: String?; let display_name: String? }
    struct Organization: Decodable, Equatable { let organization_type: String?; let rate_limit_tier: String? }
    let account: AccountInfo?
    let organization: Organization?

    /// "claude_max" + "default_claude_max_20x" → "Max 20x".
    var planName: String? {
        guard let type = organization?.organization_type else { return nil }
        var name = type.replacingOccurrences(of: "claude_", with: "").replacingOccurrences(of: "_", with: " ").capitalized
        if let tier = organization?.rate_limit_tier, let range = tier.range(of: #"\d+x$"#, options: .regularExpression) {
            name += " " + tier[range]
        }
        return name
    }
}

/// Reads Claude Code's own OAuth sign-in. Accounts using this Mac's Claude Code
/// login are read-only: Claude Code keeps renewing them, so LLM Usage never
/// refreshes or rewrites that grant (two refreshers would rotate each other out).
/// Accounts added in LLM Usage get a private Claude configuration directory that
/// only LLM Usage renews.
enum ClaudeAuth {
    static let defaultService = "Claude Code-credentials"
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let profileURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!
    static let security = "/usr/bin/security"
    /// Field names (never values) of the last renewal reply, for diagnostics.
    nonisolated(unsafe) static var lastRenewalFields: [String] = []

    struct Credentials {
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date?
        var subscriptionType: String?
        /// The complete stored document, so a renewal keeps every other field intact.
        var document: [String: Any]
        var signInExpiresAt: Date? {
            ((document["claudeAiOauth"] as? [String: Any])?["refreshTokenExpiresAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
        }
        func expires(within seconds: Double) -> Bool { expiresAt.map { $0.timeIntervalSinceNow < seconds } ?? false }
    }

    /// Claude Code suffixes its Keychain service with the first 8 hex characters
    /// of SHA-256(CLAUDE_CONFIG_DIR) when a custom configuration directory is used.
    static func service(configDir: String?) -> String {
        guard let configDir else { return defaultService }
        let digest = SHA256.hash(data: Data(configDir.utf8)).map { String(format: "%02x", $0) }.joined()
        return "\(defaultService)-\(digest.prefix(8))"
    }

    static func hasLocalSignIn() async -> Bool { (try? await read(configDir: nil)) != nil }

    static func read(configDir: String?) async throws -> Credentials {
        var data: Data?
        if let stored = try? await PoolProcess.run(security, ["find-generic-password", "-s", service(configDir: configDir), "-w"], timeout: 10) {
            data = stored
        } else if let configDir {
            // Claude Code falls back to a private file when the Keychain is unavailable.
            data = try? Data(contentsOf: URL(fileURLWithPath: configDir).appendingPathComponent(".credentials.json"))
        }
        guard let data, let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = document["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else {
            throw UsageError.message(configDir == nil
                ? "Claude Code isn’t signed in on this Mac. Run claude and sign in, then refresh."
                : "This Claude sign-in is missing. Sign in again to reconnect it.")
        }
        return Credentials(accessToken: token, refreshToken: oauth["refreshToken"] as? String,
                           expiresAt: (oauth["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) },
                           subscriptionType: oauth["subscriptionType"] as? String, document: document)
    }

    /// Renews an LLM Usage-owned sign-in and stores it where Claude Code expects it,
    /// so `CLAUDE_CONFIG_DIR=<dir> claude` keeps working with the same account.
    static func renew(_ credentials: Credentials, configDir: String) async throws -> Credentials {
        guard let refresh = credentials.refreshToken else { throw UsageError.message("Sign in again to renew this Claude account.") }
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["grant_type": "refresh_token", "refresh_token": refresh, "client_id": clientID])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = reply["access_token"] as? String else {
            throw UsageError.message("Claude didn’t renew this sign-in. Sign in again to reconnect it.")
        }
        lastRenewalFields = reply.keys.sorted()
        var document = credentials.document
        var oauth = document["claudeAiOauth"] as? [String: Any] ?? [:]
        oauth["accessToken"] = access
        if let rotated = reply["refresh_token"] as? String { oauth["refreshToken"] = rotated }
        if let seconds = reply["expires_in"] as? Double { oauth["expiresAt"] = (Date().timeIntervalSince1970 + seconds) * 1000 }
        if let seconds = reply["refresh_token_expires_in"] as? Double { oauth["refreshTokenExpiresAt"] = (Date().timeIntervalSince1970 + seconds) * 1000 }
        if let scope = reply["scope"] as? String { oauth["scopes"] = scope.split(separator: " ").map(String.init) }
        document["claudeAiOauth"] = oauth
        try await store(document, configDir: configDir)
        return try await read(configDir: configDir)
    }

    /// Writes through `security -i` with hex data so the secret never appears in process arguments.
    private static func store(_ document: [String: Any], configDir: String) async throws {
        let json = try JSONSerialization.data(withJSONObject: document)
        let hex = json.map { String(format: "%02x", $0) }.joined()
        let command = "add-generic-password -U -a \"\(NSUserName())\" -s \"\(service(configDir: configDir))\" -X \(hex)\n"
        _ = try await PoolProcess.run(security, ["-i"], input: Data(command.utf8), timeout: 10)
        guard (try? await read(configDir: configDir))?.accessToken == (document["claudeAiOauth"] as? [String: Any])?["accessToken"] as? String else {
            throw UsageError.message("The renewed Claude sign-in couldn’t be saved to the Keychain.")
        }
    }

    static func forget(configDir: String) async {
        _ = try? await PoolProcess.run(security, ["delete-generic-password", "-s", service(configDir: configDir)], timeout: 10)
        try? FileManager.default.removeItem(atPath: configDir)
    }

    static func get<T: Decodable>(_ url: URL, token: String, as type: T.Type) async throws -> T {
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UsageError.message("Claude didn’t return a valid response. Please try again.") }
        switch http.statusCode {
        case 200..<300: break
        case 401: throw ClaudeAuthExpired()
        case 403: throw UsageError.message("This Claude sign-in can’t read usage. Sign in again with a Claude subscription.")
        case 429: throw UsageError.message("Claude is receiving too many requests. Try refreshing again in a moment.")
        default: throw UsageError.message("Claude is unavailable right now (\(http.statusCode)). Your last synced usage is shown.")
        }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw UsageError.message("Claude returned usage in an unexpected format.") }
    }
}

struct ClaudeAuthExpired: LocalizedError {
    var errorDescription: String? { "This Claude sign-in has expired." }
}

/// Runs `claude auth login` in a private configuration directory. Claude Code
/// owns the OAuth exchange; LLM Usage only shows the link and passes back the
/// code the user copies from Claude's confirmation page.
final class ClaudeLoginSession: @unchecked Sendable {
    let configDir: String
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let lock = NSLock()
    private var buffer = ""
    private var urlContinuation: CheckedContinuation<URL, Error>?
    private var exitContinuation: CheckedContinuation<Int32, Never>?
    private var exitStatus: Int32?

    static func executable() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "\(home)/.claude/local/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    init(executable: String, configDir: String) {
        self.configDir = configDir
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["auth", "login", "--claudeai"]
        var environment = ProcessInfo.processInfo.environment
        environment["CLAUDE_CONFIG_DIR"] = configDir
        environment["BROWSER"] = "/usr/bin/true" // LLM Usage opens the link itself.
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
    }

    /// Starts the login and returns the authorization link Claude Code printed.
    func start() async throws -> URL {
        try FileManager.default.createDirectory(atPath: configDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            self.lock.lock()
            self.exitStatus = process.terminationStatus
            let waiting = self.exitContinuation; self.exitContinuation = nil
            let pending = self.urlContinuation; self.urlContinuation = nil
            self.lock.unlock()
            waiting?.resume(returning: process.terminationStatus)
            pending?.resume(throwing: UsageError.message("Claude Code stopped before showing a sign-in link."))
        }
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock(); urlContinuation = continuation; lock.unlock()
            output.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let chunk = handle.availableData
                guard let self, !chunk.isEmpty else { handle.readabilityHandler = nil; return }
                self.lock.lock()
                self.buffer += String(decoding: chunk, as: UTF8.self)
                var found: URL?
                if self.urlContinuation != nil,
                   let range = self.buffer.range(of: #"https://\S+/oauth/authorize\?\S+"#, options: .regularExpression) {
                    found = URL(string: String(self.buffer[range]))
                }
                let pending = found == nil ? nil : self.urlContinuation
                if found != nil { self.urlContinuation = nil }
                self.lock.unlock()
                if let found { pending?.resume(returning: found) }
            }
            do { try process.run() }
            catch {
                lock.lock(); let pending = urlContinuation; urlContinuation = nil; lock.unlock()
                pending?.resume(throwing: UsageError.message("Claude Code couldn’t be started."))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 30) { [weak self] in
                guard let self else { return }
                self.lock.lock(); let pending = self.urlContinuation; self.urlContinuation = nil; self.lock.unlock()
                if pending != nil { self.cancel() }
                pending?.resume(throwing: UsageError.message("Claude Code didn’t show a sign-in link. Try again."))
            }
        }
    }

    /// Sends the pasted code and waits for Claude Code to save the sign-in.
    func submit(code: String) async throws {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isNewline) else { throw UsageError.message("Paste the code shown by Claude.") }
        try input.fileHandleForWriting.write(contentsOf: Data((trimmed + "\n").utf8))
        let status: Int32 = await withCheckedContinuation { continuation in
            lock.lock()
            if let exitStatus { lock.unlock(); continuation.resume(returning: exitStatus); return }
            exitContinuation = continuation
            lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + 60) { [weak self] in self?.cancel() }
        }
        guard status == 0 else { throw UsageError.message("Claude didn’t accept this code. Start again for a fresh link.") }
    }

    func cancel() {
        output.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
    }
}
