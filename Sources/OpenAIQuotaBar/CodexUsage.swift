import Foundation

struct CodexUsage: Codable, Equatable {
    struct Window: Codable, Equatable {
        var usedPercent: Int
        var windowDurationMins: Int?
        var resetsAt: Int?
        var remainingPercent: Int { min(100, max(0, 100 - usedPercent)) }
        var resetDate: Date? { resetsAt.map { Date(timeIntervalSince1970: Double($0)) } }
        var title: String {
            guard let minutes = windowDurationMins else { return "Current window" }
            if minutes == 10080 { return "Weekly" }
            if minutes >= 1440, minutes % 1440 == 0 { return "\(minutes / 1440)-day" }
            if minutes >= 60, minutes % 60 == 0 { return "\(minutes / 60)-hour" }
            return "\(minutes)-minute"
        }
    }
    struct Credits: Codable, Equatable { var hasCredits: Bool; var unlimited: Bool; var balance: String? }
    struct Limits: Codable, Equatable {
        var limitId: String?
        var limitName: String?
        var primary: Window?
        var secondary: Window?
        var planType: String?
        var credits: Credits?
    }
    struct ResetCredits: Codable, Equatable { var availableCount: Int }
    var rateLimits: Limits
    var rateLimitsByLimitId: [String: Limits]?
    var rateLimitResetCredits: ResetCredits?
    var accountId: String?
    var codex: Limits {
        // Never substitute another model's quota for Codex's quota.
        if let mapped = rateLimitsByLimitId?["codex"] { return mapped }
        if rateLimits.limitId == nil || rateLimits.limitId == "codex" { return rateLimits }
        return Limits()
    }
}

struct CodexTokenUsage: Codable, Equatable {
    struct Summary: Codable, Equatable { var lifetimeTokens: Int?; var peakDailyTokens: Int? }
    var summary: Summary
}

extension Account {
    /// Name with the sign-in email, for menus where several accounts are listed together.
    var menuTitle: String {
        guard let email, !email.isEmpty, email != name else { return name }
        return "\(name) · \(email)"
    }
    var isCodex: Bool { connection == .codex }
    var isClaude: Bool { connection == .claude }
    /// Accounts whose limits come from the provider as live usage windows.
    var hasLiveQuota: Bool { isCodex || isClaude }
    var primaryWindow: CodexUsage.Window? { isClaude ? claudeUsage?.binding : codexUsage?.codex.primary }
    var secondaryWindow: CodexUsage.Window? { isClaude ? claudeUsage?.other : codexUsage?.codex.secondary }
    var planLabel: String {
        if isClaude {
            let source = claudeConfigDir == nil ? "Claude Code" : "Claude"
            guard let plan = planType, !plan.isEmpty else { return source }
            return "\(plan) · \(source)"
        }
        guard let plan = planType ?? codexUsage?.codex.planType, plan != "unknown" else { return "OpenAI · Codex" }
        return "\(plan.replacingOccurrences(of: "_", with: " ").capitalized) · Codex"
    }
    /// Days left before a Claude sign-in must be renewed by signing in again, when that is soon.
    var claudeSignInDaysLeft: Int? {
        guard isClaude, let date = claudeSignInExpiresAt else { return nil }
        let days = Int((date.timeIntervalSinceNow / 86400).rounded(.up))
        return days <= 3 ? max(0, days) : nil
    }
    /// A per-model weekly limit that is used up, e.g. "Fable". Claude refuses that model
    /// even while the account's overall weekly limit still has room.
    func exhaustedModelLimit(now: Date = Date()) -> String? {
        guard isClaude else { return nil }
        return claudeUsage?.scoped.first { $0.window.usedPercent >= 100 && ($0.window.resetDate.map { $0 > now } ?? true) }?.name
    }
    var quotaFraction: Double? {
        if hasLiveQuota { return primaryWindow.map { Double($0.remainingPercent) / 100 } }
        return remainingFraction
    }
}
