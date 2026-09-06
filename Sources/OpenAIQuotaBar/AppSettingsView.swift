import SwiftUI
import AppKit

enum AppTheme: String, Codable, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var icon: String {
        switch self {
        case .system: return "desktopcomputer"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }
    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

struct AppSettings: Codable { var theme: AppTheme }

struct AppSettingsView: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var pool: AccountPool
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Button { store.showingSettings = false } label: { Image(systemName: "arrow.left") }
                    .buttonStyle(QuietButtonStyle()).accessibilityLabel("Back").accessibilityIdentifier("settings-back")
                Text("Settings").font(.system(size: 20, weight: .semibold, design: .rounded))
                Spacer()
            }.padding(.bottom, 26)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Eyebrow(text: "Appearance")
                    Text("Your theme. Your choice.")
                        .font(.system(size: 12)).foregroundStyle(Palette.secondary).padding(.top, 8)
                    HStack(spacing: 9) {
                        ForEach(AppTheme.allCases) { theme in
                            Button {
                                do { try store.setTheme(theme); error = nil }
                                catch { self.error = "Your theme couldn’t be saved. Please try again." }
                            } label: {
                                VStack(spacing: 10) {
                                    Image(systemName: theme.icon).font(.system(size: 20, weight: .light))
                                    Text(theme.title).font(.system(size: 11, weight: .medium))
                                    Image(systemName: store.theme == theme ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 12)).opacity(store.theme == theme ? 1 : 0.25)
                                }.foregroundStyle(Palette.foreground).frame(maxWidth: .infinity).padding(.vertical, 17)
                                    .softSurface(radius: 18)
                                    .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Palette.foreground.opacity(store.theme == theme ? 0.45 : 0), lineWidth: 1))
                            }.buttonStyle(.plain).accessibilityLabel("\(theme.title) theme")
                                .accessibilityValue(store.theme == theme ? "Selected" : "Not selected")
                                .accessibilityIdentifier("theme-\(theme.rawValue)")
                        }
                    }.padding(.top, 16)
                    Text(store.theme == .system ? "Follows your Mac’s appearance." : "Only LLM Usage changes. Your Mac keeps its theme.")
                        .font(.system(size: 10)).foregroundStyle(Palette.secondary).padding(.top, 12)
                    if let error { Text(error).font(.caption).padding(.top, 10) }
                    Button { pool.showingDevices = true } label: {
                        HStack {
                            Label("Connected devices", systemImage: "desktopcomputer")
                            Spacer()
                            Text("\(pool.devices.count)").foregroundStyle(Palette.secondary)
                            Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                        }.font(.system(size: 12, weight: .medium)).padding(12).softSurface(radius: 14)
                    }.buttonStyle(.plain).padding(.top, 17).accessibilityIdentifier("devices-settings")
                    RuntimeSettingsView().padding(.top, 18)
                    HStack {
                        Eyebrow(text: "Accounts")
                        Spacer()
                        Text("\(store.visibleAccounts.count) connected").font(.system(size: 10)).foregroundStyle(Palette.secondary)
                    }.padding(.top, 29).padding(.bottom, 10)
                    VStack {
                        VStack(spacing: 5) {
                            ForEach(store.visibleAccounts) { account in
                                Button { store.startEditing(account) } label: {
                                    HStack(spacing: 10) {
                                        ProviderMark(provider: account.provider, size: 27)
                                        Text(account.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                        Spacer(minLength: 6)
                                        Image(systemName: "pencil").font(.system(size: 11)).foregroundStyle(Palette.secondary)
                                    }.padding(10).softSurface(radius: 13).contentShape(Rectangle())
                                }.buttonStyle(.plain).disabled(store.showingDemo)
                                    .accessibilityLabel("Rename \(account.name)").accessibilityIdentifier("rename-\(account.id)")
                            }
                            if store.visibleAccounts.isEmpty {
                                Text("Connect an account to see it here.").font(.system(size: 12)).foregroundStyle(Palette.secondary).padding(.vertical, 16)
                            }
                        }.padding(1)
                    }
                    Button { store.startAdding() } label: { Label("Add account", systemImage: "plus") }
                        .buttonStyle(PrimaryButtonStyle()).padding(.top, 16).accessibilityIdentifier("sign-in")
                }
            }.scrollIndicators(.hidden)
        }.padding(24)
    }
}
