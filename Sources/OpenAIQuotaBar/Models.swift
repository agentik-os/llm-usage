import Foundation

enum Provider: String, CaseIterable, Identifiable, Codable {
    case openai = "OpenAI"
    case claude = "Claude Code"
    var id: String { rawValue }
    var icon: String { self == .openai ? "sparkle" : "asterisk" }
}

struct Account: Identifiable, Codable, Equatable {
    enum Connection: String, Codable { case codex, apiKey }
    var id = UUID()
    var name: String
    var provider: Provider
    // Keep the original storage keys so existing accounts migrate without data loss.
    var monthlyLimit: Int?
    var resetDate: Date?
    var resetCredits: Int = 0
    var usedTokens: Int = 0
    var lastUpdated: Date?
    var error: String?
    var connection: Connection?
    var authSessionID: UUID?
    var email: String?
    var planType: String?
    var codexUsage: CodexUsage?
    var tokenActivity: CodexTokenUsage?

    var remaining: Int? {
        guard lastUpdated != nil, let limit = monthlyLimit, limit > 0 else { return nil }
        return max(0, limit - usedTokens)
    }
    var remainingFraction: Double? {
        guard let remaining, let limit = monthlyLimit else { return nil }
        return min(1, max(0, Double(remaining) / Double(limit)))
    }
    var initials: String {
        String(name.split(separator: " ").prefix(2).compactMap(\.first)).uppercased()
    }
}

enum TokenFormat {
    static func compact(_ value: Int) -> String {
        let magnitude = abs(Double(value))
        let divisor: Double = magnitude >= 1_000_000_000 ? 1_000_000_000 : magnitude >= 1_000_000 ? 1_000_000 : magnitude >= 1_000 ? 1_000 : 1
        let suffix = divisor == 1_000_000_000 ? "B" : divisor == 1_000_000 ? "M" : divisor == 1_000 ? "K" : ""
        return (Double(value) / divisor).formatted(.number.precision(.fractionLength(0...2))) + suffix
    }
}

extension Account {
    static var samples: [Account] {
        var accounts = [Account(id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!, name: "Personal workspace", provider: .openai,
                 monthlyLimit: 2_000_000, resetDate: Date().addingTimeInterval(3 * 86400 + 7 * 3600), resetCredits: 2,
                 usedTokens: 560_000, lastUpdated: Date()),
         Account(id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!, name: "Studio", provider: .openai,
                 monthlyLimit: 5_000_000, usedTokens: 850_000, lastUpdated: Date()),
         Account(id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!, name: "Work", provider: .openai, usedTokens: 14_600_000, lastUpdated: Date()),
         Account(id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!, name: "Research", provider: .openai, usedTokens: 2_430_000, lastUpdated: Date()),
         Account(id: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!, name: "Side projects", provider: .openai, usedTokens: 72_000, lastUpdated: Date())]
        for index in accounts.indices {
            accounts[index].connection = .codex
            accounts[index].planType = index == 0 ? "pro" : "plus"
            accounts[index].email = ["personal", "studio", "work", "research", "projects"][index] + "@example.com"
            accounts[index].codexUsage = CodexUsage(
                rateLimits: .init(limitId: "codex", primary: .init(usedPercent: [28, 17, 81, 46, 3][index], windowDurationMins: index > 1 ? 10080 : 300, resetsAt: Int(Date().timeIntervalSince1970) + 7200),
                                  secondary: .init(usedPercent: index == 0 ? 12 : 40, windowDurationMins: 10080, resetsAt: Int(Date().timeIntervalSince1970) + 3 * 86400), planType: accounts[index].planType),
                rateLimitResetCredits: .init(availableCount: index == 0 ? 2 : 0))
            accounts[index].tokenActivity = CodexTokenUsage(summary: .init(lifetimeTokens: accounts[index].usedTokens))
        }
        return accounts
    }
}
