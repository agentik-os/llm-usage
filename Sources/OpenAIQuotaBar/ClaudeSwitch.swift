import Foundation

/// Switches the account Claude Code uses on this Mac.
///
/// Claude Code keeps one sign-in per configuration directory in the Keychain and
/// re-reads it about every 30 seconds while running. Replacing that sign-in
/// therefore moves every Claude Code process that uses the directory, including
/// terminals that are already open, and every terminal opened afterwards.
enum ClaudeSwitch {
    /// The Claude Code installation whose sign-in is replaced.
    struct Target: Equatable {
        /// nil is Claude Code's default directory, which plain `claude` uses.
        var configDir: String?
        /// Claude Code's own settings file; its `oauthAccount` names the signed-in account.
        var configFile: URL

        static var claudeCode: Target {
            Target(configDir: nil, configFile: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json"))
        }
        static func directory(_ path: String) -> Target {
            Target(configDir: path, configFile: URL(fileURLWithPath: path).appendingPathComponent(".claude.json"))
        }
    }

    /// Who a sign-in belongs to, read from Claude with the sign-in itself.
    static func identify(_ credentials: ClaudeAuth.Credentials) async throws -> ClaudeProfile {
        try await ClaudeAuth.get(ClaudeAuth.profileURL, token: credentials.accessToken, as: ClaudeProfile.self)
    }

    static func sameAccount(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b, !a.isEmpty else { return false }
        return a.caseInsensitiveCompare(b) == .orderedSame
    }

    /// Puts the private sign-in in `privateDir` in force for `target`.
    /// The sign-in is renewed if needed and checked against Claude before
    /// anything is replaced, so a dead or mismatched sign-in never reaches Claude Code.
    @discardableResult
    static func activate(privateDir: String, expectedEmail: String?, target: Target) async throws -> ClaudeAuth.Credentials {
        var credentials = try await ClaudeAuth.read(configDir: privateDir)
        if credentials.expires(within: 300) { credentials = try await ClaudeAuth.renew(credentials, configDir: privateDir) }
        var profile: ClaudeProfile
        do { profile = try await identify(credentials) }
        catch is ClaudeAuthExpired {
            credentials = try await ClaudeAuth.renew(credentials, configDir: privateDir)
            profile = try await identify(credentials)
        }
        if let expectedEmail, !sameAccount(profile.account?.email, expectedEmail) {
            throw UsageError.message("This sign-in now belongs to another Claude account. Sign in again to reconnect it.")
        }
        try await ClaudeAuth.writeOAuth(credentials.oauth, configDir: target.configDir)
        // The tokens decide which account is billed; this record is what Claude Code displays.
        try? writeAccountInfo(accountInfo(privateDir: privateDir, profile: profile), target: target)
        return try await ClaudeAuth.read(configDir: target.configDir)
    }

    /// Copies the sign-in `target` holds into a private directory, so the account
    /// stays connected in LLM Usage after Claude Code moves to another one.
    static func capture(_ credentials: ClaudeAuth.Credentials, into privateDir: String, from target: Target) async throws {
        try FileManager.default.createDirectory(atPath: privateDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try await ClaudeAuth.writeOAuth(credentials.oauth, configDir: privateDir)
        let file = Target.directory(privateDir).configFile
        guard !FileManager.default.fileExists(atPath: file.path), let info = readAccountInfo(target) else { return }
        let seed: [String: Any] = ["oauthAccount": info, "hasCompletedOnboarding": true]
        try? JSONSerialization.data(withJSONObject: seed).write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    static func readAccountInfo(_ target: Target) -> [String: Any]? {
        guard let data = try? Data(contentsOf: target.configFile),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return config["oauthAccount"] as? [String: Any]
    }

    /// The account record Claude Code saved when this private sign-in was made,
    /// or the essential fields from Claude's profile when that record is missing.
    static func accountInfo(privateDir: String, profile: ClaudeProfile) -> [String: Any] {
        if let saved = readAccountInfo(.directory(privateDir)),
           sameAccount(saved["emailAddress"] as? String, profile.account?.email) { return saved }
        var info: [String: Any] = [:]
        info["emailAddress"] = profile.account?.email
        info["accountUuid"] = profile.account?.uuid
        info["displayName"] = profile.account?.display_name
        info["fullName"] = profile.account?.full_name
        info["organizationUuid"] = profile.organization?.uuid
        info["organizationName"] = profile.organization?.name
        info["organizationType"] = profile.organization?.organization_type
        info["organizationRateLimitTier"] = profile.organization?.rate_limit_tier
        return info
    }

    /// Replaces `oauthAccount` in Claude Code's settings file and leaves every other key untouched.
    /// Claude Code serializes its own saves with a `<file>.lock` directory; the same lock is taken here.
    static func writeAccountInfo(_ info: [String: Any], target: Target) throws {
        let file = target.configFile
        let lock = URL(fileURLWithPath: file.path + ".lock")
        var locked = false
        for _ in 0..<20 {
            if (try? FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false)) != nil { locked = true; break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        defer { if locked { try? FileManager.default.removeItem(at: lock) } }
        guard let data = try? Data(contentsOf: file),
              var config = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.message("Claude Code’s settings file couldn’t be read.")
        }
        if let current = config["oauthAccount"] as? NSDictionary, current.isEqual(to: info) { return }
        config["oauthAccount"] = info
        let mode = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.posixPermissions]
        try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .withoutEscapingSlashes]).write(to: file, options: .atomic)
        if let mode { try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path) }
    }
}
