import SwiftUI

/// Chooses when Claude Code leaves an account and which accounts it may move to.
struct RolloverSettingsView: View {
    @EnvironmentObject private var store: Store
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Eyebrow(text: "Claude rollover")
                Spacer()
                Toggle("Automatic rollover", isOn: Binding(get: { store.rollover.enabled }, set: { enabled in
                    update { $0.enabled = enabled }
                })).labelsHidden().toggleStyle(.switch).controlSize(.small).accessibilityIdentifier("rollover-enabled")
            }
            Text("Near a limit, Claude Code moves to the chosen account with the most usage left.")
                .font(.system(size: 12)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 8)
            if store.rollover.enabled {
                HStack(spacing: 9) {
                    ForEach(RolloverSettings.thresholds, id: \.self) { value in
                        let selected = store.rollover.threshold == value
                        Button { update { $0.threshold = value } } label: {
                            Text("\(value)%").font(.system(size: 12, weight: .medium)).monospacedDigit()
                                .foregroundStyle(Palette.foreground).frame(maxWidth: .infinity).padding(.vertical, 10)
                                .softSurface(radius: 13)
                                .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Palette.foreground.opacity(selected ? 0.45 : 0), lineWidth: 1))
                        }.buttonStyle(.plain).accessibilityLabel("Roll over at \(value) percent used")
                            .accessibilityValue(selected ? "Selected" : "Not selected")
                            .accessibilityIdentifier("rollover-threshold-\(value)")
                    }
                }.padding(.top, 16)
                Text("Share used, on any limit, that triggers the move.")
                    .font(.system(size: 10)).foregroundStyle(Palette.secondary).padding(.top, 12)
                VStack(spacing: 5) {
                    ForEach(store.rolloverAccounts) { account in
                        HStack(spacing: 10) {
                            ProviderMark(provider: account.provider, size: 27)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(account.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                Text(status(account)).font(.system(size: 10)).foregroundStyle(Palette.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 6)
                            Toggle("Roll over to \(account.name)", isOn: Binding(get: { account.inRollover == true }, set: { included in
                                do { try store.setInRollover(account.id, included); error = nil }
                                catch { self.error = "Your choice couldn’t be saved. Please try again." }
                            })).labelsHidden().toggleStyle(.switch).controlSize(.small)
                                .accessibilityIdentifier("rollover-account-\(account.id)")
                        }.padding(10).softSurface(radius: 13)
                    }
                }.padding(1).padding(.top, 15)
            }
            if let error { Text(error).font(.caption).padding(.top, 10) }
        }
    }

    private func status(_ account: Account) -> String {
        let used = ClaudeRollover.used(account).map { "\($0)% used" } ?? "Usage unavailable"
        return store.isClaudeCodeAccount(account) ? "\(used) · In use" : used
    }

    private func update(_ change: (inout RolloverSettings) -> Void) {
        var settings = store.rollover
        change(&settings)
        do { try store.setRollover(settings); error = nil }
        catch { self.error = "Your choice couldn’t be saved. Please try again." }
    }
}
