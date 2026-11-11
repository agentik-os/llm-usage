import SwiftUI

/// Marks the account Claude Code on this Mac runs on.
struct ClaudeCodeBadge: View {
    var compact = false
    var body: some View {
        Label(compact ? "In use" : "Claude Code uses this account", systemImage: "checkmark.circle.fill")
            .font(.system(size: 10, weight: .semibold))
            .help("Claude Code on this Mac runs on this account")
            .accessibilityLabel("Claude Code on this Mac runs on this account")
            .accessibilityIdentifier("claude-code-active")
    }
}

/// Moves every Claude Code terminal on this Mac to the shown account.
struct ClaudeCodeSwitchButton: View {
    let account: Account
    @EnvironmentObject private var store: Store

    var body: some View {
        VStack(spacing: 8) {
            if store.isClaudeCodeAccount(account) {
                ClaudeCodeBadge()
                TimelineView(.periodic(from: .now, by: 10)) { context in
                    Text(justSwitched(at: context.date) ? "Open terminals follow within a minute." : "Open and new terminals on this Mac.")
                        .font(.system(size: 10)).foregroundStyle(Palette.secondary)
                        .accessibilityIdentifier("claude-code-status")
                }
            } else if account.claudeConfigDir != nil {
                let switching = store.claudeSwitching == account.id
                Button { Task { await store.useInClaudeCode(account) } } label: {
                    HStack(spacing: 8) {
                        if switching { ProgressView().controlSize(.small) }
                        else { Image(systemName: "arrow.triangle.swap") }
                        Text(switching ? "Switching…" : "Use in Claude Code")
                    }
                }.buttonStyle(PrimaryButtonStyle()).disabled(!store.canSwitchClaudeCode)
                    .accessibilityIdentifier("use-in-claude-code").accessibilityLabel("Use in Claude Code")
                Text("Switches open and new terminals on this Mac.")
                    .font(.system(size: 10)).foregroundStyle(Palette.secondary)
                if let error = store.claudeSwitchError, store.claudeSwitching == nil {
                    Text(error).font(.system(size: 10)).foregroundStyle(Palette.foreground)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("claude-switch-error")
                }
            }
        }.padding(.top, 4)
    }

    private func justSwitched(at date: Date) -> Bool {
        store.claudeSwitchedAt.map { date.timeIntervalSince($0) < 60 } ?? false
    }
}
