import SwiftUI

/// A reconnect renews a saved account, never silently replaces its identity.
struct ReconnectIdentityMismatch: LocalizedError {
    let expectedEmail: String
    var errorDescription: String? {
        "Sign in with \(expectedEmail) to reconnect this account. A different account was returned; your saved account has not been changed."
    }
}

struct ReconnectAccountButton: View {
    @EnvironmentObject private var store: Store
    let account: Account

    var body: some View {
        Button { store.reconnectAccount(account) } label: {
            Label("Reconnect account", systemImage: "person.crop.circle.badge.checkmark")
        }
        .disabled(store.showingDemo || store.claudeSwitching != nil)
        .help("Sign in again without removing this account or changing its settings.")
        .accessibilityIdentifier("reconnect-account")
    }
}

extension Account {
    /// Phrases the sign-in checks use when the saved sign-in no longer works. Matched on the stored error text so
    /// every provider path (Claude Keychain, Claude renewal, Codex, devices) is covered without new plumbing.
    static func isSignInProblem(_ message: String?) -> Bool {
        guard let text = message?.lowercased(), !text.isEmpty else { return false }
        return ["sign in again", "sign-in", "signed in", "fresh sign-in", "sign in to reconnect", "unauthorized",
                "401", "token expired", "sign-in expired", "log in again", "login again", "reconnect this account"].contains { text.contains($0) }
    }

    /// True when only signing in again can fix this account, so the app shows Reconnect right where the problem is.
    var needsReconnect: Bool {
        guard hasLiveQuota else { return false }
        if claudeSignInDaysLeft == 0 { return true }
        return Account.isSignInProblem(error)
    }
}

/// Prominent call to action shown on an account that needs signing in again.
struct ReconnectNowButton: View {
    @EnvironmentObject private var store: Store
    let account: Account
    var compact = false

    var body: some View {
        Button { store.reconnectAccount(account) } label: {
            Label("Reconnect", systemImage: "arrow.triangle.2.circlepath")
                .font(.system(size: compact ? 9 : 11, weight: .semibold))
                .padding(.horizontal, compact ? 7 : 10).padding(.vertical, compact ? 3 : 5)
                .background(Palette.foreground.opacity(0.14), in: Capsule())
        }
        .buttonStyle(.plain).foregroundStyle(Palette.foreground)
        .disabled(store.showingDemo || store.claudeSwitching != nil)
        .help("This account needs to be signed in again. Its name and settings are kept.")
        .accessibilityIdentifier(compact ? "reconnect-now-row" : "reconnect-now")
    }
}
