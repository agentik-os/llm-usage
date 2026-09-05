import SwiftUI

struct CodexUsageCard: View {
    let account: Account
    private var limits: CodexUsage.Limits? { account.codexUsage?.codex }
    var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 6) {
                HStack {
                    Eyebrow(text: "Codex usage")
                    Spacer()
                    Text(limits?.primary?.title ?? "Current window").font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.secondary)
                }
                UsageGauge(account: account)
                if let date = limits?.primary?.resetDate {
                    resetLabel(date).padding(.top, -15).padding(.bottom, 2)
                } else {
                    Text(account.lastUpdated == nil ? "Syncing your account…" : "Usage window unavailable")
                        .font(.system(size: 10)).foregroundStyle(Palette.secondary).padding(.bottom, 2)
                }
                if let secondary = limits?.secondary {
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
            HStack(spacing: 0) {
                metric("Tokens used", value: account.tokenActivity?.summary.lifetimeTokens.map(TokenFormat.compact) ?? "—", detail: "All time")
                Rectangle().fill(Color.primary.opacity(0.07)).frame(width: 0.5, height: 39)
                metric("Reset credits", value: account.codexUsage?.rateLimitResetCredits.map { String($0.availableCount) } ?? "—", detail: "Available")
            }.padding(.vertical, 12).softSurface(radius: 18)
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
