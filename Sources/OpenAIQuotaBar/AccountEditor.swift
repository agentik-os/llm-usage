import SwiftUI

struct AccountEditor: View {
    @EnvironmentObject private var store: Store
    let account: Account?
    @State private var name = ""
    @State private var key = ""
    @State private var budget = ""
    @State private var hasReset = false
    @State private var resetDate = Date().addingTimeInterval(30 * 86400)
    @State private var credits = "0"
    @State private var expanded = false
    @State private var error: String?
    @State private var confirmingRemoval = false
    @FocusState private var focused: Bool

    private var valid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        (account != nil || !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) &&
        (budget.isEmpty || (Int(budget).map { $0 > 0 } ?? false)) &&
        (Int(credits).map { $0 >= 0 } ?? false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Button { store.closeEditor() } label: { Image(systemName: "arrow.left") }
                    .buttonStyle(QuietButtonStyle()).help("Back").accessibilityLabel("Back")
                Text(account == nil ? "Connect an account" : "Account settings").font(.system(size: 16, weight: .semibold, design: .rounded))
                Spacer()
            }.padding(.bottom, 21)
            ScrollView {
                VStack(alignment: .leading, spacing: 19) {
                    HStack(spacing: 10) {
                        ProviderMark(size: 40)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(account?.provider.rawValue ?? "OpenAI").font(.system(size: 14, weight: .semibold))
                            Text("Organization API usage").font(.system(size: 11)).foregroundStyle(Palette.secondary)
                        }
                        Spacer()
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.foreground)
                    }.padding(13).softSurface(radius: 17)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Connect with an organization admin key.").font(.system(size: 12, weight: .medium))
                        Text("This connection tracks API tokens. Personal ChatGPT and Codex subscription limits aren’t included.")
                            .font(.system(size: 11)).foregroundStyle(Palette.secondary).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                        Link(destination: URL(string: "https://platform.openai.com/settings/organization/admin-keys")!) {
                            HStack(spacing: 4) { Text("Open OpenAI admin keys"); Image(systemName: "arrow.up.right").font(.system(size: 8, weight: .semibold)) }
                        }.font(.system(size: 11, weight: .medium))
                    }
                    field("Account name") {
                        TextField("e.g. Personal workspace", text: $name).focused($focused)
                    }
                    field(account == nil ? "Admin key" : "Replace admin key") {
                        SecureField(account == nil ? "Paste your admin key" : "Leave blank to keep current key", text: $key)
                    }
                    field("30-day token budget · Optional") {
                        TextField("e.g. 2000000", text: $budget)
                    }
                    Text("A custom target for comparison, not a provider limit.")
                        .font(.system(size: 10)).foregroundStyle(Palette.secondary).padding(.top, -11)
                    DisclosureGroup(isExpanded: $expanded) {
                        VStack(alignment: .leading, spacing: 12) {
                            Toggle("Set a reset reminder", isOn: $hasReset).toggleStyle(.switch).controlSize(.small)
                            if hasReset { DatePicker("Date", selection: $resetDate, displayedComponents: [.date, .hourAndMinute]).labelsHidden() }
                            field("Reset credits recorded") { TextField("0", text: $credits) }
                            Text("Personal notes only. These don’t reset usage or change your OpenAI account.")
                                .font(.system(size: 10)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                        }.padding(.top, 12)
                    } label: { Text("Reset reminders & credits").font(.system(size: 11, weight: .medium)) }
                    if let error { Text(error).font(.system(size: 11)).foregroundStyle(Palette.foreground).fixedSize(horizontal: false, vertical: true) }
                    if account != nil {
                        Button("Remove this account…", role: .destructive) { confirmingRemoval = true }
                            .font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(Palette.foreground)
                    } else {
                        HStack { Image(systemName: "asterisk"); Text("Claude Code"); Spacer(); Text("Coming later").font(.system(size: 9)) }
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                }.padding(.horizontal, 1).padding(.bottom, 8)
            }.scrollIndicators(.hidden)
            VStack(spacing: 11) {
                Button(action: save) { Label(account == nil ? "Connect account" : "Save changes", systemImage: account == nil ? "link" : "checkmark") }
                    .buttonStyle(PrimaryButtonStyle()).disabled(!valid).keyboardShortcut(.defaultAction)
                Label("Your key stays in macOS Keychain.", systemImage: "lock.shield")
                    .font(.system(size: 10)).foregroundStyle(Palette.secondary)
            }.padding(.top, 18)
        }.padding(24)
            .onAppear {
                name = account?.name ?? ""
                budget = account?.monthlyLimit.map(String.init) ?? ""
                hasReset = account?.resetDate != nil
                resetDate = account?.resetDate ?? Date().addingTimeInterval(30 * 86400)
                credits = String(account?.resetCredits ?? 0)
                focused = account == nil
            }
            .alert("Remove this account?", isPresented: $confirmingRemoval) {
                Button("Cancel", role: .cancel) {}
                Button("Remove", role: .destructive) {
                    guard let account else { return }
                    do { try store.remove(account); store.closeEditor() }
                    catch { self.error = error.localizedDescription }
                }
            } message: { Text("This removes the saved account and its key from this Mac.") }
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.secondary)
            content().textFieldStyle(.plain).font(.system(size: 12)).padding(11)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.6))
                .accessibilityLabel(title)
        }
    }
    private func save() {
        guard valid else { return }
        var updated = account ?? Account(name: name, provider: .openai)
        updated.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.monthlyLimit = Int(budget)
        updated.resetDate = hasReset ? resetDate : nil
        updated.resetCredits = Int(credits) ?? 0
        do { try store.saveAccount(updated, key: key.trimmingCharacters(in: .whitespacesAndNewlines)); key = "" }
        catch { self.error = error.localizedDescription }
    }
}
