import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var pool: AccountPool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var close: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            if pool.showingDevices {
                DevicesView()
            } else if store.isSigningIn {
                SignInView()
            } else if store.showingSettings {
                AppSettingsView()
            } else if store.showingEditor {
                if let account = store.editingAccount, account.isCodex { ConnectedAccountView(account: account) }
                else { AccountEditor(account: store.editingAccount) }
            } else {
                header
                if let error = store.storageError {
                    Text(error).font(.caption).foregroundStyle(Palette.foreground).padding(.horizontal, 24).padding(.bottom, 10)
                }
                if store.showingAccountDetails, let account = store.selectedAccount { dashboard(account) }
                else if !store.visibleAccounts.isEmpty { AccountsOverview() }
                else { welcome }
                footer
            }
        }
        .frame(width: 396, height: 660)
        .font(.system(size: 12))
        .tint(Palette.foreground)
        .background {
            ZStack {
                // Keep neutral contrast over any desktop while retaining the native glass edge.
                (scheme == .dark ? Color.black.opacity(0.70) : Color.white.opacity(0.76))
                LinearGradient(colors: [.white.opacity(0.08), .clear, .black.opacity(0.025)], startPoint: .topLeading, endPoint: .bottomTrailing)
            }.allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: store.showingEditor)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: store.showingDemo)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: store.isSigningIn)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: store.showingSettings)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: store.showingAccountDetails)
    }

    private var header: some View {
        HStack(spacing: 10) {
            if store.showingAccountDetails {
                Button { store.showHome() } label: { Image(systemName: "arrow.left") }
                    .buttonStyle(QuietButtonStyle()).accessibilityLabel("All accounts").accessibilityIdentifier("all-accounts")
            } else {
                Image(systemName: "circle.hexagongrid.fill")
                    .font(.system(size: 20, weight: .medium)).foregroundStyle(Palette.foreground)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("LLM Usage").font(.system(size: 16, weight: .semibold, design: .rounded))
                Text("A little clarity for your AI.").font(.system(size: 10)).foregroundStyle(Palette.secondary)
            }
            Spacer()
            Button { store.startAdding() } label: { Image(systemName: "plus").font(.system(size: 12, weight: .medium)) }
                .buttonStyle(QuietButtonStyle()).help("Connect another account").accessibilityLabel("Connect another account").accessibilityIdentifier("add-account")
            Button { store.showingSettings = true } label: { Image(systemName: "gearshape").font(.system(size: 13, weight: .medium)) }
                .buttonStyle(QuietButtonStyle()).help("Settings").accessibilityLabel("Settings").accessibilityIdentifier("app-settings")
            Menu {
                if store.showingAccountDetails, let account = store.selectedAccount, !store.showingDemo {
                    Button("Account settings…") { store.startEditing(account) }
                    Button("Refresh usage") { Task { await store.refresh(account) } }
                    Divider()
                }
                Button("All accounts") { store.showHome() }
                Button("Settings…") { store.showingSettings = true }
                Button("Connected devices…") { pool.showingDevices = true }
                Button(store.showingDemo ? "Leave preview" : "Explore a preview") { store.showingDemo.toggle() }
                Button("Close panel") { close() }.keyboardShortcut(.escape, modifiers: [])
                Divider()
                Button("Quit LLM Usage") { NSApp.terminate(nil) }.keyboardShortcut("q")
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 14, weight: .medium)).frame(width: 28, height: 30)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("More options").accessibilityLabel("More options")
        }.padding(.horizontal, 24).padding(.top, 23).padding(.bottom, 21)
    }

    private var welcome: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 4)
            ZStack {
                Circle().strokeBorder(Palette.foreground.opacity(0.12), lineWidth: 1).frame(width: 174, height: 174)
                Circle().strokeBorder(Palette.foreground.opacity(0.10), lineWidth: 1).frame(width: 146, height: 146)
                Circle().fill(Palette.foreground.opacity(0.08)).frame(width: 118, height: 118)
                Circle().fill(.ultraThinMaterial).frame(width: 100, height: 100)
                    .overlay(Circle().strokeBorder(.white.opacity(0.55), lineWidth: 1))
                    .shadow(color: Palette.foreground.opacity(0.12), radius: 18, y: 8)
                Image(systemName: "gauge.with.dots.needle.67percent")
                    .font(.system(size: 40, weight: .ultraLight)).foregroundStyle(Palette.foreground)
                Circle().fill(Palette.foreground).frame(width: 9, height: 9).offset(x: 72, y: -49)
                Circle().fill(Palette.muted.opacity(0.7)).frame(width: 6, height: 6).offset(x: -66, y: 42)
            }.accessibilityHidden(true)
            Text("Your usage,\nat a glance.")
                .font(.system(size: 30, weight: .semibold, design: .rounded)).tracking(-0.8)
                .multilineTextAlignment(.center).lineSpacing(0).padding(.top, 19)
            Text("Sign in to OpenAI.\nSee your usage and when it resets.")
                .font(.system(size: 12)).foregroundStyle(Palette.secondary).multilineTextAlignment(.center).lineSpacing(4).padding(.top, 11)
            HStack(spacing: 22) {
                Label("Multiple accounts", systemImage: "person.2")
                Label("Secure sign-in", systemImage: "lock.shield")
            }.font(.system(size: 9, weight: .medium)).foregroundStyle(Palette.secondary).padding(.top, 25)
            Spacer(minLength: 22)
            Button { store.startAdding() } label: {
                HStack(spacing: 8) { Image(systemName: "person.crop.circle"); Text("Sign in with OpenAI"); Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .semibold)) }
            }.buttonStyle(PrimaryButtonStyle()).accessibilityIdentifier("sign-in").accessibilityLabel("Sign in with OpenAI")
            Button { store.showingDemo = true } label: { Text("Explore a preview").font(.system(size: 11, weight: .medium)).padding(10) }
                .buttonStyle(.plain).foregroundStyle(Palette.secondary).padding(.top, 4)
        }.padding(.horizontal, 28).padding(.bottom, 16).frame(maxHeight: .infinity)
    }

    private func dashboard(_ account: Account) -> some View {
        VStack(spacing: 10) {
            if store.showingDemo {
                HStack(spacing: 5) {
                    Image(systemName: "eye")
                    Text("PREVIEW · SAMPLE DATA").tracking(1)
                    Spacer()
                    Button("Done") { store.showingDemo = false }.buttonStyle(.plain).fontWeight(.semibold).accessibilityIdentifier("leave-preview").accessibilityLabel("Leave preview")
                }.font(.system(size: 9, weight: .medium)).foregroundStyle(Palette.foreground)
                    .padding(.horizontal, 11).padding(.vertical, 8).background(Palette.foreground.opacity(0.12), in: Capsule())
            }
            accountSelector(account)
            if account.isCodex { CodexUsageCard(account: account) }
            else { usageCard(account); resetDetails(account) }
            if account.isCodex, !store.showingDemo { AccountSwitchButton(account: account) }
            if let error = account.error {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(Palette.foreground)
                    Text(error).font(.system(size: 10)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                    Button { store.startEditing(account) } label: { Image(systemName: "slider.horizontal.3") }
                        .buttonStyle(.plain).help("Edit account settings").accessibilityLabel("Edit account settings")
                }.padding(12).softSurface(radius: 14)
            }
            Spacer(minLength: 0)
            if store.showingDemo {
                Button { store.startAdding() } label: { Label("Sign in with OpenAI", systemImage: "person.crop.circle") }
                    .buttonStyle(PrimaryButtonStyle()).accessibilityIdentifier("sign-in").accessibilityLabel("Sign in with OpenAI")
            } else {
                HStack(spacing: 7) {
                    Image(systemName: account.error != nil ? "exclamationmark.circle" : account.lastUpdated == nil ? "circle.dotted" : "checkmark.circle")
                        .font(.system(size: 10)).foregroundStyle(Palette.foreground)
                    if store.refreshing.contains(account.id) { Text("Syncing usage…") }
                    else if account.error != nil { Text("Sync needs attention") }
                    else if let date = account.lastUpdated {
                        Text("Updated \(date, style: .relative) ago")
                    } else { Text("Ready for your first sync") }
                    Spacer()
                    Button { store.startEditing(account) } label: { Label("Settings", systemImage: "slider.horizontal.3") }
                        .buttonStyle(.plain).help("Account settings")
                }.font(.system(size: 10)).foregroundStyle(Palette.secondary)
            }
        }.padding(.horizontal, 24).padding(.bottom, 17).frame(maxHeight: .infinity)
    }

    private func accountSelector(_ account: Account) -> some View {
        HStack(spacing: 11) {
            ProviderMark(provider: account.provider)
            Menu {
                ForEach(store.visibleAccounts) { item in
                    Button { store.selectedID = item.id } label: {
                        if item.id == account.id { Label(item.name, systemImage: "checkmark") }
                        else { Text(item.name) }
                    }
                }
                Divider()
                Button("Connect another account…") { store.startAdding() }
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(account.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(Palette.secondary)
                    }
                    Text(account.isCodex ? account.planLabel : "\(account.provider.rawValue) · Organization usage").font(.system(size: 10)).foregroundStyle(Palette.secondary)
                }
            }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button { Task { await store.refresh(account) } } label: {
                if store.refreshing.contains(account.id) { ProgressView().controlSize(.small).scaleEffect(0.7) }
                else { Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .medium)) }
            }.buttonStyle(QuietButtonStyle()).disabled(store.showingDemo || store.refreshing.contains(account.id))
                .help(store.showingDemo ? "Sample data" : "Refresh usage").accessibilityLabel("Refresh usage")
        }.padding(.vertical, 2)
    }

    private func usageCard(_ account: Account) -> some View {
        VStack(spacing: 0) {
            HStack {
                Eyebrow(text: "Token overview")
                Spacer()
                Text("Last 30 days").font(.system(size: 9, weight: .medium)).foregroundStyle(Palette.secondary)
                    .padding(.horizontal, 9).padding(.vertical, 5).background(Color.primary.opacity(0.045), in: Capsule())
            }
            UsageGauge(account: account).padding(.top, 7).padding(.bottom, 5)
            HStack {
                Label(account.remainingFraction == nil ? (account.lastUpdated == nil ? "Awaiting first sync" : "Usage synced") : "of your custom budget remaining", systemImage: account.lastUpdated == nil ? "arrow.triangle.2.circlepath" : "checkmark.circle.fill")
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.secondary)
            }.padding(.bottom, 12)
            Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 0.5)
            HStack(spacing: 0) {
                metric("Used", value: account.lastUpdated == nil ? "—" : TokenFormat.compact(account.usedTokens), dot: Palette.muted)
                Rectangle().fill(Color.primary.opacity(0.07)).frame(width: 0.5, height: 31)
                metric("Budget", value: account.monthlyLimit.map(TokenFormat.compact) ?? "Not set", dot: Palette.foreground)
            }.padding(.top, 12)
        }.padding(16).softSurface(radius: 22)
    }

    private func metric(_ title: String, value: String, dot: Color) -> some View {
        VStack(spacing: 5) {
            HStack(spacing: 5) { Circle().fill(dot).frame(width: 5, height: 5); Text(title).font(.system(size: 10)).foregroundStyle(Palette.secondary) }
            Text(value).font(.system(size: 20, weight: .medium, design: .rounded)).monospacedDigit()
        }.frame(maxWidth: .infinity)
    }

    private func resetDetails(_ account: Account) -> some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Reset reminder", systemImage: "clock.arrow.circlepath").font(.system(size: 10)).foregroundStyle(Palette.secondary)
                if let date = account.resetDate {
                    Text(date, format: .dateTime.month(.abbreviated).day().hour().minute())
                        .font(.system(size: 12, weight: .semibold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.8)
                } else { Text("Not set").font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Rectangle().fill(Color.primary.opacity(0.07)).frame(width: 0.5, height: 33).padding(.horizontal, 16)
            VStack(alignment: .leading, spacing: 8) {
                Label("Reset credits", systemImage: "arrow.counterclockwise").font(.system(size: 10)).foregroundStyle(Palette.secondary)
                Text("\(account.resetCredits) recorded").font(.system(size: 12, weight: .semibold, design: .rounded))
            }
        }.padding(16).softSurface(radius: 18)
            .accessibilityElement(children: .combine)
            .help("Manually recorded reminders and credits; these do not change your OpenAI limits.")
    }

    private var footer: some View {
        HStack(spacing: 5) {
            Image(systemName: "lock.shield").font(.system(size: 9))
            Text(store.selectedAccount == nil ? "Private by design. Right in your menu bar." : store.selectedAccount?.isCodex == true ? "Live account usage · Secured with OpenAI" : "Organization API usage · Custom budget & reminders")
                .font(.system(size: 9))
            Spacer(minLength: 0)
        }.foregroundStyle(Palette.secondary).padding(.horizontal, 24).padding(.vertical, 13)
            .overlay(alignment: .top) { Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 0.5).padding(.horizontal, 24) }
    }
}

struct UsageGauge: View {
    let account: Account
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            Circle().trim(from: 0, to: 0.78).stroke(Color.primary.opacity(0.055), style: StrokeStyle(lineWidth: 9, lineCap: .round)).rotationEffect(.degrees(129.6))
            Circle().trim(from: 0, to: 0.78 * (account.quotaFraction ?? (account.isCodex || account.lastUpdated == nil ? 0 : 1)))
                .stroke(AngularGradient(colors: [Palette.muted, Palette.foreground, Palette.foreground], center: .center, startAngle: .degrees(120), endAngle: .degrees(420)), style: StrokeStyle(lineWidth: 9, lineCap: .round))
                .rotationEffect(.degrees(129.6))
                .shadow(color: .black.opacity(0.12), radius: 3, y: 2)
            Circle().trim(from: 0, to: 0.78).stroke(Color.primary.opacity(0.12), style: StrokeStyle(lineWidth: 3, dash: [0.7, 7])).rotationEffect(.degrees(129.6)).padding(16)
            VStack(spacing: 2) {
                if let fraction = account.quotaFraction {
                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        Text("\(Int((fraction * 100).rounded()))").font(.system(size: 43, weight: .light, design: .rounded)).tracking(-2)
                        Text("%").font(.system(size: 19, weight: .regular, design: .rounded)).foregroundStyle(Palette.secondary)
                    }
                    Text("REMAINING").font(.system(size: 8, weight: .semibold)).tracking(1.9).foregroundStyle(Palette.secondary)
                } else {
                    Text(account.isCodex || account.lastUpdated == nil ? "—" : TokenFormat.compact(account.usedTokens))
                        .font(.system(size: 35, weight: .light, design: .rounded)).minimumScaleFactor(0.6).lineLimit(1)
                    Text(account.isCodex || account.lastUpdated == nil ? "NO DATA YET" : "TOKENS USED").font(.system(size: 8, weight: .semibold)).tracking(1.4).foregroundStyle(Palette.secondary)
                }
            }.offset(y: -3)
            if !account.isCodex, let remaining = account.remaining {
                Text("\(TokenFormat.compact(remaining)) tokens left").font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(Palette.secondary).offset(y: 64)
            }
        }.frame(width: 148, height: 148).padding(6)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.55), value: account.quotaFraction)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(account.isCodex ? account.quotaFraction.map { "\(Int($0 * 100)) percent of current Codex usage window remaining" } ?? "Codex usage unavailable" : account.remaining.map { "\($0.formatted()) tokens remaining from your custom budget" } ?? (account.lastUpdated == nil ? "Usage has not been synced yet" : "\(account.usedTokens.formatted()) tokens used"))
    }
}
