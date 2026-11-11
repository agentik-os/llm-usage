import SwiftUI

struct ClaudeConnectView: View {
    @EnvironmentObject private var store: Store
    @State private var code = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { store.cancelClaudeConnect() } label: { Image(systemName: "arrow.left") }
                    .buttonStyle(QuietButtonStyle()).accessibilityLabel("Cancel").accessibilityIdentifier("claude-cancel")
                Spacer()
                Text("CLAUDE ACCOUNT").font(.system(size: 9, weight: .semibold)).tracking(1.5).foregroundStyle(Palette.secondary)
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

            if case .waiting = store.claudeConnect {
                VStack(alignment: .leading, spacing: 9) {
                    Eyebrow(text: "Authentication code")
                    TextField("Paste the code from Claude", text: $code).textFieldStyle(.plain)
                        .font(.system(size: 13, design: .monospaced)).padding(14).softSurface(radius: 13)
                        .accessibilityLabel("Authentication code").accessibilityIdentifier("claude-code")
                        .onSubmit(submit)
                }.padding(.top, 26)
            } else if store.claudeConnect == .starting || store.claudeConnect == .verifying {
                ProgressView().controlSize(.small).padding(.top, 28)
            }
            Spacer()
            switch store.claudeConnect {
            case .choose:
                if store.claudeLocalAvailable {
                    Button { store.useLocalClaudeCode() } label: { Label("Use this Mac’s Claude Code", systemImage: "laptopcomputer") }
                        .buttonStyle(PrimaryButtonStyle()).accessibilityIdentifier("claude-use-local")
                    secondary("Sign in to another Claude account") { store.beginClaudeSignIn() }
                } else {
                    Button { store.beginClaudeSignIn() } label: { Label("Sign in with Claude", systemImage: "arrow.up.right") }
                        .buttonStyle(PrimaryButtonStyle()).accessibilityIdentifier("claude-sign-in")
                }
            case .waiting:
                Button(action: submit) { Label("Connect account", systemImage: "checkmark") }
                    .buttonStyle(PrimaryButtonStyle()).disabled(code.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("claude-submit")
                secondary("Reopen browser") { store.openClaudeBrowser() }
            case .failed:
                Button { code = ""; store.beginClaudeSignIn() } label: { Label("Try again", systemImage: "arrow.clockwise") }
                    .buttonStyle(PrimaryButtonStyle())
            default:
                EmptyView()
            }
            Label("Secure sign-in, powered by Claude Code", systemImage: "lock.shield")
                .font(.system(size: 10)).foregroundStyle(Palette.secondary).padding(.top, 18)
        }.padding(28)
    }

    private func secondary(_ text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(text).font(.system(size: 11)).padding(.top, 14) }
            .buttonStyle(.plain).foregroundStyle(Palette.secondary).disabled(store.isPreview)
    }

    private func submit() {
        guard !code.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        store.submitClaudeCode(code)
        code = ""
    }

    private var title: String {
        switch store.claudeConnect {
        case .waiting: return "Finish in your browser."
        case .verifying: return "Connecting your account."
        case .failed: return "Let’s try that again."
        case .starting: return "Opening Claude…"
        default: return "Connect Claude."
        }
    }
    private var subtitle: String {
        switch store.claudeConnect {
        case .waiting: return "Approve access, then copy the code\nClaude shows and paste it here."
        case .verifying: return "Reading your plan and usage."
        case .failed(let message): return message
        case .starting: return "Preparing a private sign-in."
        default: return store.claudeLocalAvailable
            ? "Use the account Claude Code is signed in\nwith, or add another Claude account."
            : "Sign in to a Claude subscription.\nYour usage, right here."
        }
    }
    private var icon: String {
        switch store.claudeConnect {
        case .verifying: return "checkmark.seal"
        case .failed: return "arrow.clockwise"
        default: return Provider.claude.icon
        }
    }
}
