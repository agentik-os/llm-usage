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
    var isCodex: Bool { connection == .codex }
    var planLabel: String {
        guard let plan = planType ?? codexUsage?.codex.planType, plan != "unknown" else { return "OpenAI · Codex" }
        return "\(plan.replacingOccurrences(of: "_", with: " ").capitalized) · Codex"
    }
    var quotaFraction: Double? {
        if isCodex { return codexUsage?.codex.primary.map { Double($0.remainingPercent) / 100 } }
        return remainingFraction
    }
}
