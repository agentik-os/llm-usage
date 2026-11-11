import Foundation

/// Automatic rollover: when the account Claude Code uses reaches the chosen share
/// of a limit, Claude Code moves to the rollover account with the most usage left.
struct RolloverSettings: Codable, Equatable {
    static let thresholds = [80, 90, 95]
    var enabled = false
    /// Percent used, on any limit, at which Claude Code leaves an account.
    var threshold = 95
}

struct RolloverEvent: Equatable {
    var from: String
    var to: String
    var date: Date
}

enum ClaudeRollover {
    /// Usage older than this is not trusted to pick an account.
    static let freshness: TimeInterval = 15 * 60

    /// The highest share used across the 5-hour, weekly and per-model limits.
    /// A window whose reset time has passed counts as reset. nil when usage is unknown.
    static func used(_ account: Account, now: Date = Date()) -> Int? {
        guard account.isClaude, let usage = account.claudeUsage else { return nil }
        let windows = [usage.session, usage.weekly].compactMap { $0 } + usage.scoped.map(\.window)
        guard !windows.isEmpty else { return nil }
        return windows.map { window in
            if let reset = window.resetDate, reset <= now { return 0 }
            return min(100, max(0, window.usedPercent))
        }.max()
    }

    static func isDue(_ account: Account, threshold: Int, now: Date = Date()) -> Bool {
        used(account, now: now).map { $0 >= threshold } ?? false
    }

    /// Whether Claude Code may be moved to this account: chosen for rollover, signed in,
    /// read without error recently, and below the threshold on every limit.
    static func isAvailable(_ account: Account, threshold: Int, now: Date = Date()) -> Bool {
        guard account.isClaude, account.claudeConfigDir != nil, account.inRollover == true, account.error == nil,
              let updated = account.lastUpdated, now.timeIntervalSince(updated) < freshness,
              let used = used(account, now: now), used < threshold else { return false }
        if let expiry = account.claudeSignInExpiresAt, expiry <= now { return false }
        return true
    }

    /// Rollover accounts Claude Code can move to, the one with the most usage left first.
    static func candidates(_ accounts: [Account], excluding active: UUID?, threshold: Int, now: Date = Date()) -> [Account] {
        accounts.enumerated()
            .filter { $0.element.id != active && isAvailable($0.element, threshold: threshold, now: now) }
            .sorted { a, b in
                let (left, right) = (used(a.element, now: now) ?? 100, used(b.element, now: now) ?? 100)
                return left == right ? a.offset < b.offset : left < right
            }
            .map(\.element)
    }
}
