import SwiftUI
import AppKit

enum Palette {
    static let foreground = gray(light: 0.10, dark: 0.94)
    static let secondary = gray(light: 0.30, dark: 0.74)
    static let muted = gray(light: 0.56, dark: 0.52)
    static let inverted = gray(light: 1, dark: 0.08)
    static let buttonTop = gray(light: 0.24, dark: 0.99)
    static let buttonBottom = gray(light: 0.07, dark: 0.82)

    private static func gray(light: CGFloat, dark: CGFloat) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            NSColor(white: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light, alpha: 1)
        })
    }
}

struct Surface: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    var radius: CGFloat = 20
    func body(content: Content) -> some View {
        content
            .background((scheme == .dark ? Color.white.opacity(0.055) : Color.white.opacity(0.38)), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Color.white.opacity(scheme == .dark ? 0.10 : 0.55), lineWidth: 0.7))
    }
}

extension View {
    func softSurface(radius: CGFloat = 20) -> some View { modifier(Surface(radius: radius)) }
}

struct QuietButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .frame(width: 32, height: 32)
            .background(Color.primary.opacity(configuration.isPressed ? 0.13 : (scheme == .dark ? 0.07 : 0.045)), in: Circle())
            .overlay(Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: 0.5))
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .contentShape(Circle())
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .foregroundStyle(Palette.inverted)
            .background(LinearGradient(colors: [Palette.buttonTop, Palette.buttonBottom], startPoint: .topLeading, endPoint: .bottomTrailing), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.55), lineWidth: 0.7))
            .shadow(color: .black.opacity(0.12), radius: 9, y: 4)
            .opacity(enabled ? (configuration.isPressed ? 0.72 : 1) : 0.45)
            .contentShape(Capsule())
    }
}

struct ProviderMark: View {
    var provider: Provider = .openai
    var size: CGFloat = 36
    var body: some View {
        Image(systemName: provider.icon)
            .font(.system(size: size * 0.45, weight: .medium))
            .foregroundStyle(Palette.foreground)
            .frame(width: size, height: size)
            .background(LinearGradient(colors: [.white.opacity(0.32), Palette.foreground.opacity(0.055)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: size * 0.32))
            .overlay(RoundedRectangle(cornerRadius: size * 0.32).strokeBorder(.white.opacity(0.35), lineWidth: 0.7))
            .accessibilityHidden(true)
    }
}

struct Eyebrow: View {
    let text: String
    var body: some View {
        Text(text.uppercased()).font(.system(size: 9, weight: .semibold)).tracking(1.5).foregroundStyle(Palette.secondary)
    }
}
