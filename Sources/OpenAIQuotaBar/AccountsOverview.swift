import SwiftUI

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
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(store.visibleAccounts) { account in
                        Button { store.openAccount(account) } label: { AccountUsageRow(account: account, syncing: store.refreshing.contains(account.id)) }
                            .buttonStyle(.plain).accessibilityIdentifier("account-row-\(account.id)")
                            .contextMenu {
                                Button("Rename account…") { store.startEditing(account) }.disabled(store.showingDemo)
                                Button("Refresh usage") { Task { await store.refresh(account) } }.disabled(store.showingDemo)
                            }
                    }
                }.padding(1)
            }.scrollIndicators(.hidden)
            if store.showingDemo {
                Button { store.startAdding() } label: { Label("Sign in with OpenAI", systemImage: "person.crop.circle") }
                    .buttonStyle(PrimaryButtonStyle()).accessibilityIdentifier("sign-in")
            } else {
                Button { pool.showingDevices = true } label: {
                    Label(pool.accountID == nil ? "Connect your devices" : "\(pool.confirmedCount) of \(pool.devices.count) devices confirmed", systemImage: "desktopcomputer")
                        .font(.system(size: 10)).foregroundStyle(Palette.secondary)
                }.buttonStyle(.plain).accessibilityIdentifier("home-devices")
            }
        }.padding(.horizontal, 24).padding(.bottom, 16).frame(maxHeight: .infinity)
    }
}

struct AccountUsageRow: View {
    @EnvironmentObject private var pool: AccountPool
    let account: Account
    let syncing: Bool
    private var fraction: Double? { account.quotaFraction.map { min(1, max(0, 1 - $0)) } }
    private var tokens: String {
        if account.isCodex {
            return account.tokenActivity?.summary.lifetimeTokens.map { "\(TokenFormat.compact($0)) tokens · all time" } ?? "Tokens unavailable"
        }
        return account.lastUpdated == nil ? "Tokens unavailable" : "\(TokenFormat.compact(account.usedTokens)) tokens · 30 days"
    }
    private var window: String { account.isCodex ? account.codexUsage?.codex.primary?.title ?? "Current window" : "Custom budget" }
    private var resetDate: Date? { account.isCodex ? account.codexUsage?.codex.primary?.resetDate : account.resetDate }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Text(account.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                if pool.accountID == account.id {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 10)).help("Selected for your devices")
                        .accessibilityLabel("Selected account")
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
                        if account.isCodex, date <= context.date {
                            Text("Reset due · refresh to update")
                        } else {
                            Text(account.isCodex ? "Resets" : "Reminder")
                            Text(date, format: .dateTime.day().month(.abbreviated).hour().minute())
                        }
                    } else {
                        Text(account.isCodex ? "Reset date unavailable" : "No reset reminder")
                    }
                    Spacer(minLength: 0)
                }.font(.system(size: 10)).foregroundStyle(Palette.secondary)
            }
            .help(resetDate.map { "\($0.formatted(date: .complete, time: .shortened)) (\(TimeZone.current.abbreviation() ?? TimeZone.current.identifier))" }
                  ?? (account.isCodex ? "OpenAI hasn’t provided a reset time for this window." : "Set a reminder in account settings."))
        }.padding(.horizontal, 14).padding(.vertical, 10).softSurface(radius: 18)
            .contentShape(RoundedRectangle(cornerRadius: 18))
            .accessibilityElement(children: .combine)
    }
}
