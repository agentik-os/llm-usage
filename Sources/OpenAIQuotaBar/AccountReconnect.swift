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
