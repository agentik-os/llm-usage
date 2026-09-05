import SwiftUI
import Security
import AppKit

final class Keychain {
    static let shared = Keychain()
    private let service = "com.openaiquotabar.keys"
    private func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString]
    }
    func set(_ value: String, for id: UUID) throws {
        let data = Data(value.utf8)
        let status = SecItemUpdate(query(id) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(id)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            try check(SecItemAdd(add as CFDictionary, nil))
        } else { try check(status) }
    }
    func get(for id: UUID) throws -> String {
        var q = query(id)
        q[kSecReturnData as String] = true
        var result: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        guard status != errSecItemNotFound else { throw UsageError.message("Add an admin key in account settings to start syncing.") }
        try check(status)
        guard let data = result as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty else {
            throw UsageError.message("Your saved key is empty. Update it in account settings.")
        }
        return key
    }
    func delete(for id: UUID) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }
    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw UsageError.message("Keychain couldn’t be updated. Please unlock your Mac and try again.")
        }
    }
}

@MainActor
final class Store: ObservableObject {
    let pool: AccountPool
    @Published private(set) var accounts: [Account] = []
    @Published var selectedID: UUID?
    @Published var showingDemo = false { didSet { showingAccountDetails = false } }
    @Published var showingAccountDetails = false
    @Published var showingSettings = false
    @Published private(set) var theme: AppTheme = .system
    @Published var showingEditor = false
    @Published var editingAccount: Account?
    @Published private(set) var refreshing: Set<UUID> = []
    @Published var storageError: String?
    @Published var signInState: SignInState?
    @Published var browserOpened = false
    @Published private(set) var canResumeSignIn = false
    var onAccountConnected: (() -> Void)?
    var onThemeChanged: ((AppTheme) -> Void)?
    private var editorReturnsToSettings = false
    private var loginClient: CodexClient?
    private var loginTask: Task<Void, Never>?
    private var completionTask: Task<Void, Never>?
    private var loginTimeout: Task<Void, Never>?
    private var loginAttempt: UUID?
    private var loginID: String?
    private var reconnecting: Account?
    private var pendingSignIn: PendingSignIn?
    private var activeClients: [UUID: CodexClient] = [:]
    private var disconnecting: Set<UUID> = []
    private let makeClient: (URL) throws -> CodexClient
    private let openBrowser: (URL) -> Bool
    private let file: URL
    private let ephemeral: Bool
    private var canPersist = true
    private let demoAccounts = Account.samples

    init(ephemeral: Bool = false, accountsFile: URL? = nil,
         makeClient: ((URL) throws -> CodexClient)? = nil,
         openBrowser: ((URL) -> Bool)? = nil) {
        self.ephemeral = ephemeral
        self.pool = AccountPool(preview: ephemeral, file: accountsFile?.deletingLastPathComponent().appendingPathComponent("pool.json"))
        self.makeClient = makeClient ?? { try CodexClient(home: $0) }
        self.openBrowser = openBrowser ?? { NSWorkspace.shared.open($0) }
        file = accountsFile ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenAIQuotaBar/accounts.json")
        if !ephemeral, let data = try? Data(contentsOf: settingsFile),
           let settings = try? JSONDecoder().decode(AppSettings.self, from: data) { theme = settings.theme }
        guard !ephemeral, FileManager.default.fileExists(atPath: file.path) else { return }
        do { accounts = try JSONDecoder().decode([Account].self, from: Data(contentsOf: file)) }
        catch { canPersist = false; storageError = "Saved accounts couldn’t be read. Your original file has been preserved." }
    }
    var visibleAccounts: [Account] { showingDemo ? demoAccounts : accounts }
    var selectedAccount: Account? { visibleAccounts.first { $0.id == selectedID } ?? visibleAccounts.first }

    var isPreview: Bool { ephemeral }
    var isSigningIn: Bool { signInState != nil }
    func startAdding() { beginSignIn() }
    func startEditing(_ account: Account) {
        guard !showingDemo else { return }
        editorReturnsToSettings = showingSettings
        showingSettings = false
        editingAccount = account
        showingEditor = true
    }
    func closeEditor() { showingEditor = false; showingSettings = editorReturnsToSettings }
    func openAccount(_ account: Account) { selectedID = account.id; showingAccountDetails = true }
    func showHome() { showingSettings = false; showingEditor = false; showingAccountDetails = false }

    private var settingsFile: URL { file.deletingLastPathComponent().appendingPathComponent("settings.json") }
    func setTheme(_ theme: AppTheme) throws {
        if !ephemeral {
            try FileManager.default.createDirectory(at: settingsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(AppSettings(theme: theme)).write(to: settingsFile, options: .atomic)
        }
        self.theme = theme
        onThemeChanged?(theme)
    }

    func renameAccount(_ id: UUID, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 60, !trimmed.contains(where: { $0.isNewline }) else {
            throw UsageError.message("Use an account name between 1 and 60 characters, on one line.")
        }
        guard let index = accounts.firstIndex(where: { $0.id == id }) else {
            throw UsageError.message("This account is no longer connected.")
        }
        // Edit the latest record so an in-flight usage refresh is preserved.
        var updated = accounts
        updated[index].name = trimmed
        try persist(updated)
        accounts = updated
        if editingAccount?.id == id { editingAccount = updated[index] }
    }

    private func sessionHome(_ id: UUID) -> URL {
        file.deletingLastPathComponent().appendingPathComponent("Sessions", isDirectory: true).appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func routingGrant(_ id: UUID, selectionID: String) async throws -> PoolGrant {
        guard !ephemeral, let account = accounts.first(where: { $0.id == id && $0.isCodex }) else {
            throw UsageError.message("Connect this account again before using it.")
        }
        let client = try makeClient(sessionHome(account.authSessionID ?? account.id))
        defer { client.stop() }
        try await client.start()
        struct Auth: Decodable { let authToken: String? }
        let reply = try JSONDecoder().decode(Auth.self, from: await client.request("getAuthStatus", params: ["includeToken": true, "refreshToken": false]))
        guard let token = reply.authToken else { throw UsageError.message("Sign in again to use this account.") }
        return try PoolGrant.make(account: account, selectionID: selectionID, token: token)
    }

    struct PendingSignIn: Codable {
        let sessionID: UUID
        let reconnectID: UUID?
    }
    private var pendingFile: URL { file.deletingLastPathComponent().appendingPathComponent("pending-signin.json") }

    private func savePendingSignIn(_ pending: PendingSignIn) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(pending).write(to: pendingFile, options: .atomic)
        pendingSignIn = pending
    }

    private func removePendingSignIn() {
        pendingSignIn = nil
        guard !ephemeral, FileManager.default.fileExists(atPath: pendingFile.path) else { return }
        do { try FileManager.default.removeItem(at: pendingFile) }
        catch { storageError = "The sign-in recovery record couldn’t be cleared." }
    }

    /// Resume only QuotaBar's explicitly recorded sign-in, never unrelated profiles.
    func resumePendingSignIn() {
        guard !ephemeral, canPersist, loginAttempt == nil else { return }
        do {
            guard FileManager.default.fileExists(atPath: pendingFile.path) else { return }
            pendingSignIn = try JSONDecoder().decode(PendingSignIn.self, from: Data(contentsOf: pendingFile))
        } catch {
            storageError = "Your unfinished sign-in couldn’t be restored."
            return
        }
        resumeSavedSignIn()
    }

    private func resumeSavedSignIn() {
        guard let pending = pendingSignIn else { return }
        let attempt = UUID()
        loginAttempt = attempt
        reconnecting = accounts.first { $0.id == pending.reconnectID }
        signInState = .completing
        canResumeSignIn = true
        completionTask = Task { [weak self] in
            await self?.finishSignIn(attempt: attempt, sessionID: pending.sessionID)
        }
    }

    func beginSignIn(browserFlow: Bool = false, reconnect account: Account? = nil) {
        cancelSignIn()
        showingEditor = false
        showingSettings = false
        reconnecting = account
        browserOpened = false
        guard canPersist else { signInState = .failed("Your saved accounts need recovery before another account can be added."); return }
        signInState = .starting
        if ephemeral {
            signInState = .waiting(DeviceSignIn(type: "chatgptDeviceCode", loginId: "preview", verificationUrl: "https://auth.openai.com/codex/device", userCode: "DEMO-1234", authUrl: nil))
            return
        }
        let attempt = UUID()
        let sessionID = UUID()
        loginAttempt = attempt
        loginTask = Task { [weak self] in
            guard let self, self.loginAttempt == attempt, !Task.isCancelled else { return }
            do {
                try savePendingSignIn(PendingSignIn(sessionID: sessionID, reconnectID: account?.id))
                let client = try makeClient(sessionHome(sessionID))
                loginClient = client
                client.notification = { [weak self] method, data in
                    guard method == "account/login/completed", let completion = try? JSONDecoder().decode(LoginCompletion.self, from: data) else { return }
                    self?.completionTask = Task { @MainActor in await self?.completeSignIn(completion, attempt: attempt, sessionID: sessionID, client: client) }
                }
                try await client.start()
                guard loginAttempt == attempt else { return }
                let data = try await client.request("account/login/start", params: ["type": browserFlow ? "chatgpt" : "chatgptDeviceCode"])
                let challenge = try JSONDecoder().decode(DeviceSignIn.self, from: data)
                guard loginAttempt == attempt else { return }
                guard challenge.browserURL != nil else { throw UsageError.message("OpenAI returned an invalid sign-in link. Please try again.") }
                loginID = challenge.loginId
                // A very fast browser callback can finish before the response is handled.
                if signInState == .starting {
                    signInState = .waiting(challenge)
                    openSignInBrowser()
                }
                guard signInState != .completing else { return }
                loginTimeout = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: 15 * 60 * 1_000_000_000) } catch { return }
                    guard let self, self.loginAttempt == attempt else { return }
                    self.cancelSignIn()
                    self.signInState = .failed("This sign-in expired. Try again for a fresh code.")
                }
            } catch {
                guard loginAttempt == attempt else { return }
                loginClient?.stop()
                signInState = .failed(error.localizedDescription)
            }
        }
    }

    func openSignInBrowser() {
        guard !ephemeral, case let .waiting(challenge) = signInState, let url = challenge.browserURL else { return }
        browserOpened = openBrowser(url)
    }
    func retrySignIn(browserFlow: Bool = false) {
        if canResumeSignIn, !browserFlow { resumeSavedSignIn() }
        else { beginSignIn(browserFlow: browserFlow, reconnect: reconnecting) }
    }

    private func completeSignIn(_ result: LoginCompletion, attempt: UUID, sessionID: UUID, client: CodexClient) async {
        guard loginAttempt == attempt, signInState != .completing else { return }
        if let expected = loginID, result.loginId != expected { return }
        guard result.success else {
            loginTimeout?.cancel()
            signInState = .failed("Sign-in wasn’t completed. Try again, or use browser sign-in.")
            client.stop()
            return
        }
        signInState = .completing
        canResumeSignIn = true
        loginTimeout?.cancel()
        // The login server can still have the pre-login account cached after success.
        // Reopen the same isolated profile to load the credentials Codex just saved.
        client.stop()
        await finishSignIn(attempt: attempt, sessionID: sessionID)
    }

    private func signedInIdentity(sessionID: UUID, attempt: UUID) async throws -> CodexIdentity.Details {
        for delay: UInt64 in [0, 250_000_000, 750_000_000, 1_500_000_000] {
            if delay > 0 { try await Task.sleep(nanoseconds: delay) }
            try Task.checkCancellation()
            guard loginAttempt == attempt else { throw CancellationError() }
            let client = try makeClient(sessionHome(sessionID))
            loginClient = client
            defer { client.stop() }
            try await client.start()
            let data = try await client.request("account/read", params: ["refreshToken": false])
            let identity = try JSONDecoder().decode(CodexIdentity.self, from: data)
            if let details = identity.account, details.type == "chatgpt" { return details }
        }
        throw UsageError.message("Your account is still loading. Try again to finish connecting, or use browser sign-in.")
    }

    private func finishSignIn(attempt: UUID, sessionID: UUID) async {
        do {
            let details = try await signedInIdentity(sessionID: sessionID, attempt: attempt)
            guard loginAttempt == attempt else { return }
            var account = accounts.first { $0.authSessionID == sessionID } ?? reconnecting
                ?? Account(name: details.email?.components(separatedBy: "@").first ?? "OpenAI account", provider: .openai)
            let previousSession = account.authSessionID
            account.connection = .codex
            account.authSessionID = sessionID
            account.email = details.email
            account.planType = details.planType
            account.error = nil
            account.codexUsage = nil
            account.tokenActivity = nil
            account.lastUpdated = nil
            activeClients[account.id]?.stop()
            var updated = accounts
            if let index = updated.firstIndex(where: { $0.id == account.id }) { updated[index] = account }
            else { updated.append(account) }
            try persist(updated)
            accounts = updated
            selectedID = account.id
            showingDemo = false
            showingAccountDetails = false
            signInState = nil
            loginAttempt = nil
            loginClient = nil
            loginID = nil
            reconnecting = nil
            canResumeSignIn = false
            removePendingSignIn()
            onAccountConnected?()
            if let previousSession, previousSession != sessionID { Task { await self.clearSession(previousSession) } }
            await refresh(account)
        } catch {
            guard loginAttempt == attempt else { return }
            signInState = .failed(error.localizedDescription)
            loginClient?.stop()
        }
    }

    func cancelSignIn() {
        let client = loginClient
        let id = loginID
        let pending = pendingSignIn
        loginAttempt = nil
        loginTask?.cancel()
        completionTask?.cancel()
        loginTimeout?.cancel()
        loginClient = nil
        loginID = nil
        signInState = nil
        canResumeSignIn = false
        removePendingSignIn()
        client?.notification = nil
        if let client {
            Task {
                if let id { _ = try? await client.request("account/login/cancel", params: ["loginId": id], timeout: 3) }
                // This profile is new and isolated; cleanup cannot sign out an existing account.
                _ = try? await client.request("account/logout", timeout: 3)
                client.stop()
                // A completed login uses a fresh reader, which may already be stopped.
                if let pending { await self.clearSession(pending.sessionID) }
            }
        }
    }

    private func clearSession(_ id: UUID) async {
        guard let client = try? makeClient(sessionHome(id)) else { return }
        defer { client.stop() }
        do { try await client.start(); _ = try await client.request("account/logout") } catch { }
    }

    func disconnect(_ account: Account) async throws {
        guard pool.accountID != account.id else { throw UsageError.message("Switch to another account before disconnecting the account your devices are using.") }
        disconnecting.insert(account.id)
        defer { disconnecting.remove(account.id) }
        activeClients[account.id]?.stop()
        if account.isCodex, !ephemeral {
            let client = try makeClient(sessionHome(account.authSessionID ?? account.id))
            defer { client.stop() }
            try await client.start()
            _ = try await client.request("account/logout")
        }
        try remove(account)
    }

    func shutdown() {
        pool.stop()
        loginTask?.cancel()
        completionTask?.cancel()
        loginTimeout?.cancel()
        loginClient?.stop()
        activeClients.values.forEach { $0.stop() }
    }

    func saveAccount(_ account: Account, key: String) throws {
        guard canPersist else { throw UsageError.message("Restore the saved accounts file before adding accounts. The original file has not been changed.") }
        if !key.isEmpty, !ephemeral { try Keychain.shared.set(key, for: account.id) }
        var updated = accounts
        if let i = updated.firstIndex(where: { $0.id == account.id }) { updated[i] = account }
        else { updated.append(account) }
        try persist(updated)
        accounts = updated
        selectedID = account.id
        showingDemo = false
        closeEditor()
        if !ephemeral { Task { await refresh(account) } }
    }
    func remove(_ account: Account) throws {
        let updated = accounts.filter { $0.id != account.id }
        try persist(updated)
        accounts = updated
        selectedID = accounts.first?.id
        if !ephemeral, !account.isCodex { try Keychain.shared.delete(for: account.id) }
    }
    private func persist(_ accounts: [Account]) throws {
        guard !ephemeral else { return }
        guard canPersist else { throw UsageError.message("The saved accounts file needs recovery before changes can be saved.") }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(accounts).write(to: file, options: .atomic)
    }
    func refresh(_ account: Account) async {
        guard !showingDemo, !ephemeral, !refreshing.contains(account.id), !disconnecting.contains(account.id) else { return }
        refreshing.insert(account.id)
        defer {
            refreshing.remove(account.id)
            if let current = accounts.first(where: { $0.id == account.id }), current.authSessionID != account.authSessionID {
                Task { await self.refresh(current) }
            }
        }
        if account.isCodex {
            await refreshCodex(account)
            return
        }
        var value: Int?
        var failure: String?
        do {
            guard account.provider == .openai else { throw UsageError.message("The Claude Code connector isn’t available yet.") }
            value = try await OpenAIUsage.fetch(adminKey: Keychain.shared.get(for: account.id))
        } catch { failure = error.localizedDescription }
        // Resolve the account after awaiting: switching or deleting accounts must be safe.
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[index].error = failure
        if let value { accounts[index].usedTokens = value; accounts[index].lastUpdated = Date() }
        do { try persist(accounts) } catch { storageError = "Usage updated, but couldn’t be saved to disk." }
    }
    private func refreshCodex(_ account: Account) async {
        do {
            let client = try makeClient(sessionHome(account.authSessionID ?? account.id))
            activeClients[account.id] = client
            defer { client.stop(); activeClients.removeValue(forKey: account.id) }
            try await client.start()
            let limits = try JSONDecoder().decode(CodexUsage.self, from: await client.request("account/rateLimits/read"))
            let activityData = try? await client.request("account/usage/read", timeout: 15)
            let activity = activityData.flatMap { try? JSONDecoder().decode(CodexTokenUsage.self, from: $0) }
            guard let index = accounts.firstIndex(where: { $0.id == account.id && $0.authSessionID == account.authSessionID }) else { return }
            accounts[index].codexUsage = limits
            accounts[index].tokenActivity = activity
            accounts[index].planType = limits.codex.planType ?? accounts[index].planType
            accounts[index].lastUpdated = Date()
            accounts[index].error = nil
        } catch {
            guard let index = accounts.firstIndex(where: { $0.id == account.id && $0.authSessionID == account.authSessionID }) else { return }
            accounts[index].error = error.localizedDescription
        }
        do { try persist(accounts) } catch { storageError = "Usage updated, but couldn’t be saved to disk." }
    }
    func refreshStale() async {
        guard !showingDemo else { return }
        for account in accounts where account.lastUpdated.map({ Date().timeIntervalSince($0) > 300 }) ?? true {
            await refresh(account)
        }
    }
    func refreshAll() async {
        guard !showingDemo, !ephemeral else { return }
        for account in accounts { await refresh(account) }
    }
}

enum UsageError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}

enum OpenAIUsage {
    struct Page: Decodable {
        struct Bucket: Decodable {
            struct Result: Decodable { let input_tokens: Int; let output_tokens: Int }
            let results: [Result]
        }
        let data: [Bucket]
        let has_more: Bool?
        let next_page: String?
        var total: Int { data.flatMap(\.results).reduce(0) { $0 + $1.input_tokens + $1.output_tokens } }
    }
    static func fetch(adminKey: String) async throws -> Int {
        let end = Int(Date().timeIntervalSince1970)
        let start = end - 30 * 24 * 3600
        var cursor: String?
        var seenCursors = Set<String>()
        var total = 0
        repeat {
            var components = URLComponents(string: "https://api.openai.com/v1/organization/usage/completions")!
            components.queryItems = [URLQueryItem(name: "start_time", value: "\(start)"), URLQueryItem(name: "end_time", value: "\(end)"),
                                    URLQueryItem(name: "limit", value: "31"), URLQueryItem(name: "bucket_width", value: "1d")]
            if let cursor { components.queryItems?.append(URLQueryItem(name: "page", value: cursor)) }
            var request = URLRequest(url: components.url!)
            request.timeoutInterval = 25
            request.setValue("Bearer \(adminKey)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw UsageError.message("OpenAI didn’t return a valid response. Please try again.") }
            guard (200..<300).contains(http.statusCode) else {
                let message: String
                switch http.statusCode {
                case 401, 403: message = "This key can’t read organization usage. Check your OpenAI admin key in account settings."
                case 429: message = "OpenAI is receiving too many requests. Try refreshing again in a moment."
                default: message = "OpenAI is unavailable right now (\(http.statusCode)). Your last synced usage is shown."
                }
                throw UsageError.message(message)
            }
            let page = try JSONDecoder().decode(Page.self, from: data)
            total += page.total
            cursor = nil
            if page.has_more == true {
                guard let next = page.next_page, !next.isEmpty, seenCursors.insert(next).inserted else {
                    throw UsageError.message("OpenAI returned incomplete usage. Please refresh again.")
                }
                cursor = next
            }
        } while cursor != nil
        return total
    }
}
