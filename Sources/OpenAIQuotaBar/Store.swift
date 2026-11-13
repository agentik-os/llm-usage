import SwiftUI
import Security
import AppKit

final class Keychain {
    static let shared = Keychain()
    // Keep the pre-rename Keychain service so existing API accounts remain accessible.
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
    @Published var showingLocal = false
    @Published private(set) var theme: AppTheme = .system
    @Published var showingEditor = false
    @Published var editingAccount: Account?
    @Published private(set) var refreshing: Set<UUID> = []
    @Published var storageError: String?
    private var hermesSyncing = false
    @Published var signInState: SignInState?
    @Published var browserOpened = false
    @Published private(set) var canResumeSignIn = false
    @Published var claudeConnect: ClaudeConnectState?
    @Published private(set) var claudeLocalAvailable = false
    private var claudeLogin: ClaudeLoginSession?
    @Published private(set) var claudeReconnecting: Account?
    /// The account Claude Code on this Mac is signed in to, confirmed by Claude for the sign-in in force.
    @Published private(set) var claudeCode: ClaudeCodeState?
    @Published private(set) var claudeSwitching: UUID?
    @Published private(set) var claudeSwitchedAt: Date?
    @Published var claudeSwitchError: String?
    private var claudeCodeChecked: Date?
    @Published private(set) var rollover = RolloverSettings()
    @Published var rolloverEvent: RolloverEvent?
    /// Why a due rollover couldn't happen, e.g. no chosen account has usage left.
    @Published private(set) var rolloverNotice: String?
    private var rollingOver = false
    private let claudeTarget: ClaudeSwitch.Target
    var onAccountConnected: (() -> Void)?
    var onThemeChanged: ((AppTheme) -> Void)?
    private var editorReturnsToSettings = false
    private var loginClient: CodexClient?
    private var loginTask: Task<Void, Never>?
    private var completionTask: Task<Void, Never>?
    private var loginTimeout: Task<Void, Never>?
    private var loginAttempt: UUID?
    private var loginID: String?
    @Published private(set) var reconnecting: Account?
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
         openBrowser: ((URL) -> Bool)? = nil,
         claudeTarget: ClaudeSwitch.Target = .claudeCode) {
        self.ephemeral = ephemeral
        self.claudeTarget = claudeTarget
        self.pool = AccountPool(preview: ephemeral, file: accountsFile?.deletingLastPathComponent().appendingPathComponent("pool.json"))
        self.makeClient = makeClient ?? { try CodexClient(home: $0) }
        self.openBrowser = openBrowser ?? { NSWorkspace.shared.open($0) }
        file = accountsFile ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenAIQuotaBar/accounts.json")
        if !ephemeral, let data = try? Data(contentsOf: settingsFile),
           let settings = try? JSONDecoder().decode(AppSettings.self, from: data) {
            theme = settings.theme
            rollover = settings.rollover ?? RolloverSettings()
        }
        guard !ephemeral, FileManager.default.fileExists(atPath: file.path) else { return }
        do { accounts = try JSONDecoder().decode([Account].self, from: Data(contentsOf: file)) }
        catch { canPersist = false; storageError = "Saved accounts couldn’t be read. Your original file has been preserved." }
        if canPersist { pruneClaudeSessions() }
        claudeCode = (try? Data(contentsOf: claudeCodeFile)).flatMap { try? JSONDecoder().decode(ClaudeCodeState.self, from: $0) }
    }

    /// Removes private Claude sign-ins left by an interrupted connection (e.g. quitting mid-sign-in).
    private func pruneClaudeSessions() {
        let used = Set(accounts.compactMap(\.claudeConfigDir))
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: claudeSessionsRoot.path) else { return }
        for name in entries {
            let dir = claudeSessionsRoot.appendingPathComponent(name, isDirectory: true).path
            if !used.contains(dir) { Task { await ClaudeAuth.forget(configDir: dir) } }
        }
    }
    var visibleAccounts: [Account] { showingDemo ? demoAccounts : accounts }
    var selectedAccount: Account? { visibleAccounts.first { $0.id == selectedID } ?? visibleAccounts.first }

    var isPreview: Bool { ephemeral }
    var isSigningIn: Bool { signInState != nil }
    func startAdding() { beginSignIn() }
    func reconnectAccount(_ account: Account) {
        guard !showingDemo, claudeSwitching == nil, account.hasLiveQuota,
              let current = accounts.first(where: { $0.id == account.id }) else { return }
        openAccount(current)
        if current.isClaude { startClaudeConnect(reconnect: current) }
        else { beginSignIn(reconnect: current) }
    }

    /// Resolve the latest record after authentication so renames and rollover choices survive.
    func accountForReconnect(_ original: Account?, authenticatedEmail: String?) throws -> Account? {
        guard let original else { return nil }
        guard let current = accounts.first(where: { $0.id == original.id && $0.provider == original.provider }) else {
            throw UsageError.message("This account was removed. Cancel and connect it as a new account.")
        }
        if let expected = current.email, !expected.isEmpty,
           !ClaudeSwitch.sameAccount(expected, authenticatedEmail) {
            throw ReconnectIdentityMismatch(expectedEmail: expected)
        }
        return current
    }
    func startEditing(_ account: Account) {
        guard !showingDemo else { return }
        editorReturnsToSettings = showingSettings
        showingSettings = false
        editingAccount = account
        showingEditor = true
    }
    func closeEditor() { showingEditor = false; showingSettings = editorReturnsToSettings }
    func openAccount(_ account: Account) { selectedID = account.id; showingAccountDetails = true }
    func showHome() { showingSettings = false; showingLocal = false; showingEditor = false; showingAccountDetails = false }

    private var settingsFile: URL { file.deletingLastPathComponent().appendingPathComponent("settings.json") }
    func setTheme(_ theme: AppTheme) throws {
        try saveSettings(AppSettings(theme: theme, rollover: rollover))
        self.theme = theme
        onThemeChanged?(theme)
    }

    private func saveSettings(_ settings: AppSettings) throws {
        guard !ephemeral else { return }
        try FileManager.default.createDirectory(at: settingsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(settings).write(to: settingsFile, options: .atomic)
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
        var reply = try JSONDecoder().decode(Auth.self, from: await client.request("getAuthStatus", params: ["includeToken": true, "refreshToken": false]))
        if let token = reply.authToken, PoolGrant.needsRefresh(token) {
            // The existing native sign-in owns refresh credentials. Ask Codex
            // to renew them there instead of copying refresh tokens to Hermes.
            reply = try JSONDecoder().decode(Auth.self, from: await client.request("getAuthStatus", params: ["includeToken": true, "refreshToken": true]))
        }
        guard let token = reply.authToken else { throw UsageError.message("Sign in again to use this account.") }
        return try PoolGrant.make(account: account, selectionID: selectionID, token: token)
    }

    func synchronizeHermes() async {
        guard !ephemeral, !showingDemo, !hermesSyncing, !isSigningIn,
              refreshing.isEmpty, let configuration = HermesPoolSync.configuration else { return }
        let source = accounts.filter { $0.isCodex }
        guard !source.isEmpty else { return }
        hermesSyncing = true
        defer { hermesSyncing = false }
        do {
            var grants: [PoolGrant] = []
            for account in source {
                grants.append(try await routingGrant(account.id, selectionID: "hermes-local"))
            }
            let current = accounts.filter { $0.isCodex }
            guard current.count == source.count, zip(current, source).allSatisfy({
                $0.id == $1.id && $0.authSessionID == $1.authSessionID && $0.name == $1.name
            }) else {
                return
            }
            _ = try await HermesPoolSync.apply(grants, configuration: configuration)
        } catch {
            HermesPoolSync.reportFailure()
        }
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

    /// Resume only LLM Usage's explicitly recorded sign-in, never unrelated profiles.
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
        cancelClaudeConnect()
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
            let reconnected = try accountForReconnect(reconnecting, authenticatedEmail: details.email)
            var account = accounts.first { $0.authSessionID == sessionID } ?? reconnected
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
            showingAccountDetails = reconnected != nil
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
        guard !pool.isInUse(account.id) else { throw UsageError.message("Switch to another account before disconnecting the account your devices are using.") }
        disconnecting.insert(account.id)
        defer { disconnecting.remove(account.id) }
        activeClients[account.id]?.stop()
        if account.isClaude, !ephemeral, let dir = account.claudeConfigDir {
            // Only LLM Usage's private sign-in is removed; this Mac's Claude Code login is never touched.
            await ClaudeAuth.forget(configDir: dir)
        }
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
        claudeLogin?.cancel()
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
        if !ephemeral, !account.hasLiveQuota { try Keychain.shared.delete(for: account.id) }
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
        if account.isClaude {
            await refreshClaude(account)
            return
        }
        var value: Int?
        var failure: String?
        do {
            guard account.provider == .openai else { throw UsageError.message("Connect this Claude account again.") }
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
    // MARK: Claude

    private var claudeSessionsRoot: URL { file.deletingLastPathComponent().appendingPathComponent("ClaudeSessions", isDirectory: true) }

    func startClaudeConnect(reconnect account: Account? = nil) {
        cancelSignIn()
        cancelClaudeConnect()
        showingEditor = false
        showingSettings = false
        claudeReconnecting = account
        guard canPersist else { claudeConnect = .failed("Your saved accounts need recovery before another account can be added."); return }
        if let account, account.claudeConfigDir != nil { beginClaudeSignIn(); return }
        claudeConnect = .choose
        guard !ephemeral else { claudeLocalAvailable = true; return }
        Task {
            let available = await ClaudeAuth.hasLocalSignIn()
            await syncClaudeCode()
            // Offered only while no connected account already shows Claude Code's sign-in.
            claudeLocalAvailable = available && !accounts.contains { isClaudeCodeAccount($0) }
        }
    }

    /// Adds this Mac's Claude Code sign-in without copying or renewing it.
    func useLocalClaudeCode() {
        guard !ephemeral else { return }
        claudeConnect = .verifying
        Task {
            do {
                let credentials = try await ClaudeAuth.read(configDir: nil)
                try await addClaudeAccount(configDir: nil, credentials: credentials)
            } catch { claudeConnect = .failed(error.localizedDescription) }
        }
    }

    func beginClaudeSignIn() {
        guard !ephemeral else { claudeConnect = .waiting(URL(string: "https://claude.com")!); return }
        guard let executable = ClaudeLoginSession.executable() else {
            claudeConnect = .failed("Install Claude Code to sign in to another Claude account.")
            return
        }
        claudeLogin?.cancel()
        let dir = claudeSessionsRoot.appendingPathComponent(UUID().uuidString, isDirectory: true).path
        let session = ClaudeLoginSession(executable: executable, configDir: dir)
        claudeLogin = session
        claudeConnect = .starting
        Task {
            do {
                let url = try await session.start()
                guard claudeLogin === session else { return }
                claudeConnect = .waiting(url)
                _ = openBrowser(url)
            } catch {
                guard claudeLogin === session else { return }
                claudeConnect = .failed(error.localizedDescription)
                await ClaudeAuth.forget(configDir: dir)
            }
        }
    }

    func openClaudeBrowser() {
        guard !ephemeral, case let .waiting(url) = claudeConnect else { return }
        _ = openBrowser(url)
    }

    func submitClaudeCode(_ code: String) {
        guard let session = claudeLogin, case .waiting = claudeConnect else { return }
        claudeConnect = .verifying
        Task {
            do {
                try await session.submit(code: code)
                let credentials = try await ClaudeAuth.read(configDir: session.configDir)
                guard claudeLogin === session else { return }
                try await addClaudeAccount(configDir: session.configDir, credentials: credentials)
                claudeLogin = nil
            } catch {
                guard claudeLogin === session else { return }
                claudeLogin = nil
                claudeConnect = .failed(error.localizedDescription)
                await ClaudeAuth.forget(configDir: session.configDir)
            }
        }
    }

    func cancelClaudeConnect() {
        if let session = claudeLogin {
            session.cancel()
            Task { await ClaudeAuth.forget(configDir: session.configDir) }
        }
        claudeLogin = nil
        claudeConnect = nil
        claudeReconnecting = nil
    }

    private func addClaudeAccount(configDir: String?, credentials: ClaudeAuth.Credentials) async throws {
        let profile = try await ClaudeAuth.get(ClaudeAuth.profileURL, token: credentials.accessToken, as: ClaudeProfile.self)
        let email = profile.account?.email
        if let duplicate = accounts.first(where: { $0.isClaude && $0.email != nil && $0.email == email && $0.id != claudeReconnecting?.id }) {
            throw UsageError.message("\(duplicate.name) already shows this Claude account.")
        }
        let reconnected = try accountForReconnect(claudeReconnecting, authenticatedEmail: email)
        var account = reconnected ?? Account(name: email?.components(separatedBy: "@").first ?? "Claude account", provider: .claude)
        let previousDir = account.claudeConfigDir
        account.provider = .claude
        account.connection = .claude
        account.claudeConfigDir = configDir
        account.email = email
        account.planType = profile.planName ?? credentials.subscriptionType
        account.error = nil
        account.claudeUsage = nil
        account.lastUpdated = nil
        var updated = accounts
        if let index = updated.firstIndex(where: { $0.id == account.id }) { updated[index] = account }
        else { updated.append(account) }
        try persist(updated)
        accounts = updated
        if let previousDir, previousDir != configDir { await ClaudeAuth.forget(configDir: previousDir) }
        if let configDir, ClaudeSwitch.sameAccount(email, claudeCode?.email) {
            // A fresh sign-in for the account Claude Code already uses replaces Claude Code's
            // older one, so both keep sharing a single sign-in instead of renewing against each other.
            if let active = try? await ClaudeSwitch.activate(privateDir: configDir, expectedEmail: email, target: claudeTarget) {
                setClaudeCode(ClaudeCodeState(email: email, tokenDigest: active.digest))
            }
        }
        selectedID = account.id
        showingDemo = false
        showingAccountDetails = reconnected != nil
        claudeConnect = nil
        claudeReconnecting = nil
        onAccountConnected?()
        await refresh(account)
    }

    private func refreshClaude(_ account: Account) async {
        var usage: ClaudeUsage?
        var failure: String?
        var signInExpiry: Date?
        await syncClaudeCode()
        do {
            // The account Claude Code uses shares Claude Code's sign-in, which Claude Code renews.
            let shared = account.claudeConfigDir != nil && isClaudeCodeAccount(account)
            var credentials = try await ClaudeAuth.read(configDir: shared ? claudeTarget.configDir : account.claudeConfigDir)
            defer { signInExpiry = credentials.signInExpiresAt }
            if let dir = account.claudeConfigDir, credentials.expires(within: shared ? 0 : 300) {
                credentials = try await renewClaude(credentials, dir: dir, shared: shared)
            }
            do {
                usage = ClaudeUsage(try await ClaudeAuth.get(ClaudeAuth.usageURL, token: credentials.accessToken, as: ClaudeUsage.Response.self))
            } catch is ClaudeAuthExpired {
                guard let dir = account.claudeConfigDir else {
                    throw UsageError.message("Claude Code renews this sign-in when you use it. Open Claude Code, then refresh.")
                }
                credentials = try await renewClaude(credentials, dir: dir, shared: shared)
                usage = ClaudeUsage(try await ClaudeAuth.get(ClaudeAuth.usageURL, token: credentials.accessToken, as: ClaudeUsage.Response.self))
            }
        } catch { failure = error.localizedDescription }
        guard let index = accounts.firstIndex(where: { $0.id == account.id && $0.claudeConfigDir == account.claudeConfigDir }) else { return }
        accounts[index].error = failure
        if let signInExpiry { accounts[index].claudeSignInExpiresAt = signInExpiry }
        if let usage { accounts[index].claudeUsage = usage; accounts[index].lastUpdated = Date() }
        do { try persist(accounts) } catch { storageError = "Usage updated, but couldn’t be saved to disk." }
    }

    /// Renews a private sign-in. For the account Claude Code uses, Claude Code may have
    /// renewed first: its newer sign-in is adopted, otherwise the renewal is handed to it.
    private func renewClaude(_ credentials: ClaudeAuth.Credentials, dir: String, shared: Bool) async throws -> ClaudeAuth.Credentials {
        guard shared else { return try await ClaudeAuth.renew(credentials, configDir: dir) }
        if let current = try? await ClaudeAuth.read(configDir: claudeTarget.configDir),
           current.accessToken != credentials.accessToken, !current.expires(within: 0) { return current }
        do {
            let renewed = try await ClaudeAuth.renew(credentials, configDir: dir)
            try await ClaudeAuth.writeOAuth(renewed.oauth, configDir: claudeTarget.configDir)
            if let email = claudeCode?.email { setClaudeCode(ClaudeCodeState(email: email, tokenDigest: renewed.digest)) }
            return renewed
        } catch {
            // Claude Code won the race for the same renewal; its result is the valid sign-in.
            if let current = try? await ClaudeAuth.read(configDir: claudeTarget.configDir),
               current.accessToken != credentials.accessToken { return current }
            throw error
        }
    }

    // MARK: Claude Code account switching

    private var claudeCodeFile: URL { file.deletingLastPathComponent().appendingPathComponent("claude-code.json") }

    /// Whether Claude Code on this Mac currently runs on this account.
    func isClaudeCodeAccount(_ account: Account) -> Bool {
        guard account.isClaude else { return false }
        if showingDemo { return false }
        return account.claudeConfigDir == nil || ClaudeSwitch.sameAccount(account.email, claudeCode?.email)
    }
    var canSwitchClaudeCode: Bool { !ephemeral && !showingDemo && canPersist && claudeSwitching == nil }

    private func setClaudeCode(_ state: ClaudeCodeState?) {
        guard state != claudeCode else { return }
        claudeCode = state
        guard !ephemeral else { return }
        if let state, let data = try? JSONEncoder().encode(state) { try? data.write(to: claudeCodeFile, options: .atomic) }
        else { try? FileManager.default.removeItem(at: claudeCodeFile) }
    }

    /// Reads which account Claude Code is signed in to and keeps that account's private
    /// copy identical to Claude Code's sign-in. Claude is asked only when the sign-in changed
    /// (a renewal by Claude Code, or `/login` in a terminal), never on a plain refresh.
    func syncClaudeCode(force: Bool = false) async {
        guard !ephemeral, claudeSwitching == nil || force, accounts.contains(where: \.isClaude) else { return }
        if !force, let checked = claudeCodeChecked, Date().timeIntervalSince(checked) < 5 { return }
        claudeCodeChecked = Date()
        guard let current = try? await ClaudeAuth.read(configDir: claudeTarget.configDir) else { setClaudeCode(nil); return }
        if current.digest != claudeCode?.tokenDigest {
            // An unreadable identity (offline, expired, rate-limited) changes nothing; it is checked again later.
            guard let profile = try? await ClaudeSwitch.identify(current), let email = profile.account?.email else { return }
            setClaudeCode(ClaudeCodeState(email: email, tokenDigest: current.digest))
        }
        // Only a sign-in Claude confirmed for this account ever overwrites the private copy.
        guard let owner = accounts.first(where: { $0.claudeConfigDir != nil && isClaudeCodeAccount($0) }), let dir = owner.claudeConfigDir,
              (try? await ClaudeAuth.read(configDir: dir))?.accessToken != current.accessToken else { return }
        try? await ClaudeAuth.writeOAuth(current.oauth, configDir: dir)
    }

    /// Moves Claude Code on this Mac to `account`: terminals that are already open follow
    /// within about a minute, and every terminal opened afterwards starts on it.
    func useInClaudeCode(_ account: Account) async {
        guard canSwitchClaudeCode, account.isClaude, let dir = account.claudeConfigDir, !isClaudeCodeAccount(account) else { return }
        claudeSwitching = account.id
        claudeSwitchError = nil
        defer { claudeSwitching = nil }
        do {
            // Keep the outgoing account's newest sign-in before it leaves Claude Code.
            await syncClaudeCode(force: true)
            try await keepCurrentClaudeCodeSignIn()
            let active = try await ClaudeSwitch.activate(privateDir: dir, expectedEmail: account.email, target: claudeTarget)
            setClaudeCode(ClaudeCodeState(email: account.email, tokenDigest: active.digest))
            claudeSwitchedAt = Date()
        } catch {
            claudeSwitchError = error.localizedDescription
            return
        }
        for item in accounts where item.isClaude && (item.id == account.id || item.error != nil) { await refresh(item) }
    }

    /// Claude Code's present sign-in must stay connected somewhere before it is replaced.
    /// An account LLM Usage doesn't hold privately yet becomes its own private account.
    private func keepCurrentClaudeCodeSignIn() async throws {
        guard let state = claudeCode, let current = try? await ClaudeAuth.read(configDir: claudeTarget.configDir),
              current.digest == state.tokenDigest,
              !accounts.contains(where: { $0.claudeConfigDir != nil && ClaudeSwitch.sameAccount($0.email, state.email) }) else { return }
        let dir = claudeSessionsRoot.appendingPathComponent(UUID().uuidString, isDirectory: true).path
        try await ClaudeSwitch.capture(current, into: dir, from: claudeTarget)
        var updated = accounts
        if let index = updated.firstIndex(where: { $0.isClaude && $0.claudeConfigDir == nil }) {
            updated[index].claudeConfigDir = dir
            updated[index].email = state.email
        } else {
            var kept = Account(name: state.email?.components(separatedBy: "@").first ?? "Claude account", provider: .claude)
            kept.connection = .claude
            kept.claudeConfigDir = dir
            kept.email = state.email
            kept.planType = current.subscriptionType?.capitalized
            updated.append(kept)
        }
        do { try persist(updated) } catch { await ClaudeAuth.forget(configDir: dir); throw error }
        accounts = updated
    }

    // MARK: Claude rollover

    func setRollover(_ settings: RolloverSettings) throws {
        var settings = settings
        settings.threshold = min(100, max(1, settings.threshold))
        try saveSettings(AppSettings(theme: theme, rollover: settings))
        rollover = settings
        rolloverNotice = nil
        if settings.enabled { Task { await rolloverTick() } }
    }

    func setInRollover(_ id: UUID, _ included: Bool) throws {
        guard let index = accounts.firstIndex(where: { $0.id == id && $0.isClaude }) else { return }
        var updated = accounts
        updated[index].inRollover = included ? true : nil
        try persist(updated)
        accounts = updated
        rolloverNotice = nil
        if rollover.enabled { Task { await evaluateRollover() } }
    }

    /// Rollover accounts with a private sign-in, the only ones Claude Code can be moved to.
    var rolloverAccounts: [Account] { accounts.filter { $0.isClaude && $0.claudeConfigDir != nil } }

    /// Keeps the account Claude Code uses fresh between full refreshes, so the threshold is noticed in time.
    func rolloverTick() async {
        guard rollover.enabled, !ephemeral, !showingDemo else { return }
        await syncClaudeCode()
        if let active = accounts.first(where: { isClaudeCodeAccount($0) }),
           active.lastUpdated.map({ Date().timeIntervalSince($0) > 100 }) ?? true { await refresh(active) }
        await evaluateRollover()
    }

    /// Moves Claude Code off an account that reached the threshold, to the chosen account with the most usage left.
    func evaluateRollover() async {
        guard rollover.enabled, !ephemeral, !showingDemo, !rollingOver, claudeSwitching == nil,
              let active = accounts.first(where: { isClaudeCodeAccount($0) }) else { return }
        guard ClaudeRollover.isDue(active, threshold: rollover.threshold) else { rolloverNotice = nil; return }
        rollingOver = true
        defer { rollingOver = false }
        let used = ClaudeRollover.used(active) ?? rollover.threshold
        for candidate in ClaudeRollover.candidates(accounts, excluding: active.id, threshold: rollover.threshold) {
            // Decide on a reading taken now: another terminal may have used this account since the last refresh.
            if candidate.lastUpdated.map({ Date().timeIntervalSince($0) > 60 }) ?? true { await refresh(candidate) }
            guard let current = accounts.first(where: { $0.id == candidate.id }),
                  ClaudeRollover.isAvailable(current, threshold: rollover.threshold), canSwitchClaudeCode else { continue }
            await useInClaudeCode(current)
            guard isClaudeCodeAccount(current) else { continue }
            claudeSwitchError = nil
            rolloverNotice = nil
            rolloverEvent = RolloverEvent(from: active.name, to: current.name, date: Date())
            return
        }
        claudeSwitchError = nil
        rolloverNotice = rolloverAccounts.contains(where: { $0.inRollover == true && $0.id != active.id })
            ? "\(active.name) is at \(used)%. No rollover account has usage left."
            : "\(active.name) is at \(used)%. Choose rollover accounts in Settings."
    }

    // MARK: Codex reset credits

    /// Redeems one Codex rate-limit reset credit through the account's own Codex sign-in.
    /// Returns a short user-facing outcome; usage is re-read afterwards so the gauge shows the backend's result.
    func useResetCredit(_ account: Account) async throws -> String {
        guard !ephemeral, !showingDemo, account.isCodex else { throw UsageError.message("Reset credits are available for OpenAI accounts only.") }
        struct Reply: Decodable { let outcome: String }
        let client = try makeClient(sessionHome(account.authSessionID ?? account.id))
        defer { client.stop() }
        try await client.start()
        // One key per attempt: a retried request can never redeem a second credit.
        let reply = try JSONDecoder().decode(Reply.self, from: await client.request("account/rateLimitResetCredit/consume", params: ["idempotencyKey": UUID().uuidString], timeout: 30))
        client.stop()
        if let current = accounts.first(where: { $0.id == account.id }) { await refresh(current) }
        switch reply.outcome {
        case "reset": return "Your Codex limit was reset."
        case "nothingToReset": return "Nothing to reset right now, so no credit was used."
        case "noCredit": return "No reset credit is available for this account."
        case "alreadyRedeemed": return "This reset credit was already used."
        default: return "OpenAI returned an unrecognized result. Check your usage before trying again."
        }
    }

    func refreshStale() async {
        guard !showingDemo else { return }
        await syncClaudeCode()
        for account in accounts where account.lastUpdated.map({ Date().timeIntervalSince($0) > 300 }) ?? true {
            await refresh(account)
        }
        await evaluateRollover()
    }
    func refreshAll() async {
        guard !showingDemo, !ephemeral else { return }
        await syncClaudeCode()
        for account in accounts { await refresh(account) }
        await evaluateRollover()
        await synchronizeHermes()
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

/// Which account Claude Code is signed in to; the digest identifies the confirmed sign-in without storing it.
struct ClaudeCodeState: Codable, Equatable {
    var email: String?
    var tokenDigest: String
}

enum ClaudeConnectState: Equatable {
    case choose, starting, waiting(URL), verifying, failed(String)
}
