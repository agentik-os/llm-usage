import SwiftUI
import AppKit

struct AccountsOverview: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var pool: AccountPool

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your accounts").font(.system(size: 21, weight: .semibold, design: .rounded)).tracking(-0.4)
                    Text("\(store.visibleAccounts.count) accounts · Usage at a glance")
                        .font(.system(size: 10)).foregroundStyle(Palette.secondary)
                }
                Spacer()
                Button { Task { await store.refreshAll() } } label: {
                    if store.refreshing.isEmpty { Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .medium)) }
                    else { ProgressView().controlSize(.small).scaleEffect(0.7) }
                }.buttonStyle(QuietButtonStyle()).disabled(store.showingDemo || !store.refreshing.isEmpty)
                    .accessibilityLabel("Refresh all accounts").help("Refresh all accounts")
            }
            if store.showingDemo {
                HStack {
                    Label("PREVIEW · SAMPLE DATA", systemImage: "eye").tracking(1)
                    Spacer()
                    Button("Done") { store.showingDemo = false }.buttonStyle(.plain).fontWeight(.semibold)
                        .accessibilityIdentifier("leave-preview")
                }.font(.system(size: 9)).foregroundStyle(Palette.secondary)
            }
            if let error = store.claudeSwitchError, store.claudeSwitching == nil, !store.showingDemo {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(Palette.foreground)
                    Text(error).font(.system(size: 10)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button { store.claudeSwitchError = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).accessibilityLabel("Dismiss")
                }.padding(12).softSurface(radius: 14).accessibilityIdentifier("claude-switch-error")
            }
            if !store.showingDemo, store.rolloverNotice != nil || store.rolloverEvent != nil {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: store.rolloverNotice == nil ? "arrow.triangle.2.circlepath" : "exclamationmark.circle").foregroundStyle(Palette.foreground)
                    if let notice = store.rolloverNotice {
                        Text(notice).fixedSize(horizontal: false, vertical: true)
                    } else if let event = store.rolloverEvent {
                        Text("Rolled over from \(event.from) to \(event.to) at \(event.date.formatted(date: .omitted, time: .shortened)).")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    if store.rolloverNotice == nil {
                        Button { store.rolloverEvent = nil } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain).accessibilityLabel("Dismiss")
                    }
                }.font(.system(size: 10)).foregroundStyle(Palette.secondary).padding(12).softSurface(radius: 14)
                    .accessibilityElement(children: .combine).accessibilityIdentifier("rollover-status")
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(store.visibleAccounts) { account in
                        Button { store.openAccount(account) } label: { AccountUsageRow(account: account, syncing: store.refreshing.contains(account.id)) }
                            .buttonStyle(.plain).accessibilityIdentifier("account-row-\(account.id)")
                            .help(account.email ?? "")
                            .contextMenu {
                                if let email = account.email, !email.isEmpty {
                                    Button("Copy \(email)") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(email, forType: .string)
                                    }
                                    Divider()
                                }
                                Button("Rename account…") { store.startEditing(account) }.disabled(store.showingDemo)
                                Button("Refresh usage") { Task { await store.refresh(account) } }.disabled(store.showingDemo)
                                if account.hasLiveQuota { ReconnectAccountButton(account: account) }
                                if account.isClaude, account.claudeConfigDir != nil, !store.showingDemo {
                                    Button(account.inRollover == true ? "Remove from rollover" : "Add to rollover") {
                                        try? store.setInRollover(account.id, account.inRollover != true)
                                    }
                                }
                                if account.isClaude, account.claudeConfigDir != nil, !store.isClaudeCodeAccount(account) {
                                    Button("Use in Claude Code") { Task { await store.useInClaudeCode(account) } }.disabled(!store.canSwitchClaudeCode)
                                }
                            }
                    }
                }.padding(1)
            }.scrollIndicators(.hidden)
            if store.showingDemo {
                Button { store.startAdding() } label: { Label("Sign in with OpenAI", systemImage: "person.crop.circle") }
                    .buttonStyle(PrimaryButtonStyle()).accessibilityIdentifier("sign-in")
            } else {
                Button { pool.showingDevices = true } label: {
                    Label(pool.selections.isEmpty ? "Connect your devices" : "\(pool.confirmedCount) of \(pool.selectedCount) selected devices ready", systemImage: "desktopcomputer")
                        .font(.system(size: 10)).foregroundStyle(Palette.secondary)
                }.buttonStyle(.plain).accessibilityIdentifier("home-devices")
            }
        }.padding(.horizontal, 24).padding(.bottom, 16).frame(maxHeight: .infinity)
    }
}

struct AccountUsageRow: View {
    @EnvironmentObject private var pool: AccountPool
    @EnvironmentObject private var store: Store
    let account: Account
    let syncing: Bool
    private var fraction: Double? { account.quotaFraction.map { min(1, max(0, 1 - $0)) } }
    private var tokens: String {
        if account.isClaude {
            return account.secondaryWindow.map { "\($0.title) · \($0.remainingPercent)% left" } ?? account.planLabel
        }
        if account.isCodex {
            return account.tokenActivity?.summary.lifetimeTokens.map { "\(TokenFormat.compact($0)) tokens · all time" } ?? "Tokens unavailable"
        }
        return account.lastUpdated == nil ? "Tokens unavailable" : "\(TokenFormat.compact(account.usedTokens)) tokens · 30 days"
    }
    private var window: String { account.hasLiveQuota ? account.primaryWindow?.title ?? "Current window" : "Custom budget" }
    private var resetDate: Date? { account.hasLiveQuota ? account.primaryWindow?.resetDate : account.resetDate }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Text(account.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                if store.claudeSwitching == account.id {
                    Label("Switching…", systemImage: "arrow.triangle.swap").font(.system(size: 9)).foregroundStyle(Palette.secondary)
                } else if store.isClaudeCodeAccount(account) {
                    ClaudeCodeBadge(compact: true)
                } else if !pool.activeDevices(for: account.id).isEmpty {
                    ActiveAccountBadge(names: pool.activeDevices(for: account.id).map(\.name).joined(separator: ", "), compact: true)
                } else if pool.isSelected(account.id) {
                    Label("Pending", systemImage: "clock").font(.system(size: 9)).foregroundStyle(Palette.secondary)
                }
                if account.inRollover == true, store.rollover.enabled, !store.showingDemo {
                    Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.secondary)
                        .help("In automatic rollover").accessibilityLabel("In automatic rollover")
                }
                Spacer(minLength: 2)
                if let fraction {
                    Text("\(Int((fraction * 100).rounded()))% used").font(.system(size: 11, weight: .semibold)).monospacedDigit()
                } else { Text("—").font(.system(size: 13)).foregroundStyle(Palette.secondary) }
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(Palette.secondary)
            }
            HStack(spacing: 6) {
                if syncing { Text("Syncing…") }
                else if account.error != nil { Label("Needs attention", systemImage: "exclamationmark.circle") }
                else if let days = account.claudeSignInDaysLeft { Label(days == 0 ? "Sign in again" : "Sign in again in \(days)d", systemImage: "clock.badge.exclamationmark") }
                else if let model = account.exhaustedModelLimit() { Label("\(model) limit reached", systemImage: "exclamationmark.circle").accessibilityIdentifier("model-limit-reached") }
                else { Text(window) }
                Spacer(minLength: 2)
                Text(tokens).lineLimit(1).minimumScaleFactor(0.85)
            }.font(.system(size: 9)).foregroundStyle(Palette.secondary)
            GeometryReader { proxy in
                Capsule().fill(Color.primary.opacity(0.07))
                    .overlay(alignment: .leading) {
                        if let fraction { Capsule().fill(Palette.foreground).frame(width: proxy.size.width * fraction) }
                    }
            }.frame(height: 4)
            TimelineView(.periodic(from: .now, by: 60)) { context in
                HStack(spacing: 4) {
                    Image(systemName: "clock.arrow.circlepath").accessibilityHidden(true)
                    if let date = resetDate {
                        if account.hasLiveQuota, date <= context.date {
                            Text("Reset due · refresh to update")
                        } else {
                            Text(account.hasLiveQuota ? "Resets" : "Reminder")
                            Text(date, format: .dateTime.day().month(.abbreviated).hour().minute())
                        }
                    } else {
                        Text(account.hasLiveQuota ? "Reset date unavailable" : "No reset reminder")
                    }
                    Spacer(minLength: 0)
                }.font(.system(size: 10)).foregroundStyle(Palette.secondary)
            }
            .help(resetDate.map { "\($0.formatted(date: .complete, time: .shortened)) (\(TimeZone.current.abbreviation() ?? TimeZone.current.identifier))" }
                  ?? (account.hasLiveQuota ? "The provider hasn’t given a reset time for this window." : "Set a reminder in account settings."))
        }.padding(.horizontal, 14).padding(.vertical, 10).softSurface(radius: 18)
            .contentShape(RoundedRectangle(cornerRadius: 18))
            .accessibilityElement(children: .combine)
    }
}
