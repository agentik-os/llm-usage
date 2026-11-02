import SwiftUI

struct CodexUsageCard: View {
    @EnvironmentObject private var store: Store
    let account: Account
    @State private var confirmingReset = false
    @State private var resetting = false
    @State private var resetMessage: String?
    private var resetCredits: Int { account.codexUsage?.rateLimitResetCredits?.availableCount ?? 0 }
    var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 6) {
                HStack {
                    Eyebrow(text: account.isClaude ? "Claude usage" : "Codex usage")
                    Spacer()
                    Text(account.primaryWindow?.title ?? "Current window").font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.secondary)
                }
                UsageGauge(account: account)
                if let date = account.primaryWindow?.resetDate {
                    resetLabel(date).padding(.top, -15).padding(.bottom, 2)
                } else {
                    Text(account.lastUpdated == nil ? "Syncing your account…" : "Usage window unavailable")
                        .font(.system(size: 10)).foregroundStyle(Palette.secondary).padding(.bottom, 2)
                }
                if let secondary = account.secondaryWindow {
                    Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 0.5)
                    VStack(spacing: 6) {
                        HStack {
                            Text(secondary.title).foregroundStyle(Palette.secondary)
                            Spacer()
                            Text("\(secondary.remainingPercent)% left").fontWeight(.semibold).monospacedDigit()
                        }.font(.system(size: 11))
                        GeometryReader { proxy in
                            Capsule().fill(Color.primary.opacity(0.06))
                                .overlay(alignment: .leading) { Capsule().fill(Palette.foreground).frame(width: proxy.size.width * CGFloat(secondary.remainingPercent) / 100) }
                        }.frame(height: 5)
                        if let date = secondary.resetDate { HStack { resetLabel(date); Spacer() } }
                    }.padding(.top, 6)
                }
            }.padding(16).softSurface(radius: 22)
            if account.isClaude {
                if let scoped = account.claudeUsage?.scoped, !scoped.isEmpty {
                    VStack(spacing: 9) {
                        ForEach(scoped, id: \.name) { item in
                            HStack {
                                Text("\(item.name) · \(item.window.title)").foregroundStyle(Palette.secondary)
                                Spacer()
                                Text("\(item.window.remainingPercent)% left").fontWeight(.semibold).monospacedDigit()
                            }.font(.system(size: 11))
                        }
                    }.padding(14).softSurface(radius: 18)
                }
            } else {
            HStack(spacing: 0) {
                metric("Tokens used", value: account.tokenActivity?.summary.lifetimeTokens.map(TokenFormat.compact) ?? "—", detail: "All time")
                Rectangle().fill(Color.primary.opacity(0.07)).frame(width: 0.5, height: 39)
                metric("Reset credits", value: account.codexUsage?.rateLimitResetCredits.map { String($0.availableCount) } ?? "—", detail: "Available")
            }.padding(.vertical, 12).softSurface(radius: 18)
            if resetCredits > 0 || resetMessage != nil, !store.showingDemo {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.counterclockwise.circle").foregroundStyle(Palette.foreground)
                    Text(resetMessage ?? "\(resetCredits) reset credit\(resetCredits == 1 ? "" : "s") available")
                        .font(.system(size: 10)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if resetCredits > 0 {
                        Button(resetting ? "Resetting…" : "Use a reset") { confirmingReset = true }
                            .buttonStyle(.plain).font(.system(size: 10, weight: .semibold)).disabled(resetting)
                            .accessibilityIdentifier("use-reset-credit")
                    }
                }.padding(12).softSurface(radius: 14)
                .alert("Use one reset credit?", isPresented: $confirmingReset) {
                    Button("Cancel", role: .cancel) {}
                    Button("Use reset") {
                        resetting = true
                        Task {
                            do { resetMessage = try await store.useResetCredit(account) }
                            catch { resetMessage = error.localizedDescription }
                            resetting = false
                        }
                    }
                } message: {
                    Text("This resets \(account.name)’s current Codex usage window and uses one of its \(resetCredits) credit\(resetCredits == 1 ? "" : "s"). It can’t be undone.")
                }
            }
            }
        }
    }
    private func resetLabel(_ date: Date) -> some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            if date > context.date {
                HStack(spacing: 4) { Image(systemName: "clock"); Text("Resets \(date, style: .relative)"); Text("from now") }
                    .font(.system(size: 10)).foregroundStyle(Palette.secondary)
            } else {
                Text("Reset due · refresh to update").font(.system(size: 10)).foregroundStyle(Palette.secondary)
            }
        }.help(date.formatted(date: .abbreviated, time: .shortened))
    }
    private func metric(_ title: String, value: String, detail: String) -> some View {
        VStack(spacing: 5) {
            Text(title).font(.system(size: 10)).foregroundStyle(Palette.secondary)
            Text(value).font(.system(size: 22, weight: .medium, design: .rounded)).monospacedDigit()
            Text(detail).font(.system(size: 9)).foregroundStyle(Palette.secondary)
        }.frame(maxWidth: .infinity)
    }
}
