import SwiftUI
import AppKit

struct SignInView: View {
    @EnvironmentObject private var store: Store
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { store.cancelSignIn() } label: { Image(systemName: "arrow.left") }
                    .buttonStyle(QuietButtonStyle()).accessibilityLabel("Cancel sign-in")
                Spacer()
                Text("OPENAI ACCOUNT").font(.system(size: 9, weight: .semibold)).tracking(1.5).foregroundStyle(Palette.secondary)
                Spacer()
                Color.clear.frame(width: 32, height: 32)
            }
            Spacer()
            ZStack {
                Circle().fill(Palette.foreground.opacity(0.08)).frame(width: 136, height: 136)
                Circle().strokeBorder(Palette.foreground.opacity(0.15), lineWidth: 1).frame(width: 160, height: 160)
                Image(systemName: icon).font(.system(size: 40, weight: .light)).foregroundStyle(Palette.foreground)
            }.accessibilityHidden(true)
            Text(title).font(.system(size: 27, weight: .semibold, design: .rounded)).tracking(-0.6)
                .multilineTextAlignment(.center).padding(.top, 25)
            Text(subtitle).font(.system(size: 12)).foregroundStyle(Palette.secondary)
                .multilineTextAlignment(.center).lineSpacing(4).fixedSize(horizontal: false, vertical: true).padding(.top, 12)

            if case let .waiting(challenge) = store.signInState {
                if let code = challenge.userCode {
                    VStack(spacing: 12) {
                        Eyebrow(text: store.isPreview ? "Preview · Sample code" : "Your one-time code")
                        Text(code).font(.system(size: 28, weight: .medium, design: .monospaced)).tracking(2)
                            .textSelection(.enabled).accessibilityLabel("One-time code: \(code)")
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(code, forType: .string)
                            copied = true
                        } label: { Label(copied ? "Copied" : "Copy code", systemImage: copied ? "checkmark" : "doc.on.doc") }
                            .font(.system(size: 11, weight: .medium)).buttonStyle(.plain).foregroundStyle(Palette.foreground)
                    }.padding(19).frame(maxWidth: .infinity).softSurface(radius: 20).padding(.top, 26)
                }
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                    Text("Waiting for you to finish signing in…").font(.system(size: 10)).foregroundStyle(Palette.secondary)
                }.padding(.top, 21)
            } else if store.signInState == .starting || store.signInState == .completing {
                ProgressView().controlSize(.small).padding(.top, 28)
            }
            Spacer()
            if case .failed = store.signInState {
                Button { store.retrySignIn() } label: { Label("Try again", systemImage: "arrow.clockwise") }
                    .buttonStyle(PrimaryButtonStyle())
                browserAlternative
            } else if case let .waiting(challenge) = store.signInState {
                Button { store.openSignInBrowser() } label: { Label(store.browserOpened ? "Reopen browser" : "Open browser", systemImage: "arrow.up.right") }
                    .buttonStyle(PrimaryButtonStyle()).disabled(store.isPreview)
                if challenge.userCode != nil { browserAlternative }
            }
            Label("Secure sign-in, powered by Codex", systemImage: "lock.shield")
                .font(.system(size: 10)).foregroundStyle(Palette.secondary).padding(.top, 18)
        }.padding(28)
    }

    private var browserAlternative: some View {
        Button { store.retrySignIn(browserFlow: true) } label: { Text("Use browser sign-in instead").font(.system(size: 11)).padding(.top, 14) }
            .buttonStyle(.plain).foregroundStyle(Palette.secondary).disabled(store.isPreview)
    }
    private var title: String {
        switch store.signInState {
        case .waiting: return "Finish in your browser."
        case .completing: return "Connecting your account."
        case .failed: return store.canResumeSignIn ? "Almost there." : "Let’s try that again."
        default: return "Opening OpenAI…"
        }
    }
    private var subtitle: String {
        switch store.signInState {
        case .waiting(let challenge): return challenge.userCode == nil
            ? "Sign in to your OpenAI account.\nWe’ll take care of the rest."
            : "Sign in to OpenAI, then enter this code.\nYour account will appear here automatically."
        case .completing: return "Getting your account ready."
        case .failed(let message): return message
        default: return "One secure sign-in.\nYour usage, right here."
        }
    }
    private var icon: String {
        switch store.signInState {
        case .completing: return "checkmark.seal"
        case .failed: return "arrow.clockwise"
        default: return "person.crop.circle.badge.checkmark"
        }
    }
}

struct ConnectedAccountView: View {
    @EnvironmentObject private var store: Store
    let account: Account
    @State private var confirming = false
    @State private var removing = false
    @State private var error: String?
    @State private var accountName: String

    init(account: Account) {
        self.account = account
        _accountName = State(initialValue: account.name)
    }

    private var validName: Bool {
        let value = accountName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !value.isEmpty && value.count <= 60 && !value.contains(where: { $0.isNewline })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { store.closeEditor() } label: { Image(systemName: "arrow.left") }
                    .buttonStyle(QuietButtonStyle()).accessibilityLabel("Back").accessibilityIdentifier("account-settings-back")
                Spacer()
                Text("Your account").font(.system(size: 15, weight: .semibold, design: .rounded))
                Spacer()
                Color.clear.frame(width: 32, height: 32)
            }
            Spacer()
            ProviderMark(size: 66)
            Text(account.email ?? account.name).font(.system(size: 18, weight: .semibold, design: .rounded))
                .lineLimit(2).multilineTextAlignment(.center).textSelection(.enabled).padding(.top, 20)
            Text(account.planLabel).font(.system(size: 12)).foregroundStyle(Palette.secondary).padding(.top, 7)
            Label("Connected securely", systemImage: "checkmark.shield")
                .font(.system(size: 11)).foregroundStyle(Palette.foreground).padding(.top, 18)
            VStack(alignment: .leading, spacing: 9) {
                Eyebrow(text: "Account name")
                TextField("e.g. Personal", text: $accountName).textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .medium)).padding(14).softSurface(radius: 13)
                    .accessibilityLabel("Account name").accessibilityIdentifier("account-name")
                    .onSubmit(saveName)
                Text("A name to help you recognize this account.").font(.system(size: 10)).foregroundStyle(Palette.secondary)
            }.padding(.top, 28)
            Spacer()
            if let error { Text(error).font(.caption).foregroundStyle(Palette.foreground).padding(.bottom, 15) }
            Button(action: saveName) { Label("Save name", systemImage: "checkmark") }
                .buttonStyle(PrimaryButtonStyle()).disabled(!validName || removing).accessibilityIdentifier("save-account-name")
            Button { store.beginSignIn(reconnect: account) } label: { Label("Sign in again", systemImage: "arrow.clockwise") }
                .buttonStyle(.plain).font(.system(size: 11)).padding(.top, 18).disabled(removing)
            Button(removing ? "Disconnecting…" : "Disconnect account") { confirming = true }
                .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Palette.secondary).padding(.top, 18).disabled(removing)
            Text("Your other accounts stay signed in.").font(.system(size: 10)).foregroundStyle(Palette.secondary).padding(.top, 24)
        }.padding(28)
            .alert("Disconnect this account?", isPresented: $confirming) {
                Button("Cancel", role: .cancel) {}
                Button("Disconnect", role: .destructive) {
                    removing = true
                    Task {
                        do { try await store.disconnect(account); store.closeEditor() }
                        catch { self.error = error.localizedDescription }
                        removing = false
                    }
                }
            } message: { Text("This only signs the account out of LLM Usage.") }
    }

    private func saveName() {
        guard validName, !removing else { return }
        do { try store.renameAccount(account.id, to: accountName); store.closeEditor() }
        catch { self.error = error.localizedDescription }
    }
}
