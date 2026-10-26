import SwiftUI

enum NotchThemeID: String, CaseIterable, Identifiable {
    case aegis
    case `default`
    case glass
    case pixel
    case terminal
    case brutalist
    case webSlinger

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .aegis:    return "Aegis"
        case .default:    return "Default"
        case .glass:      return "Liquid Glass"
        case .pixel:      return "Retro Pixel"
        case .terminal:   return "Terminal"
        case .brutalist:  return "Brutalist"
        case .webSlinger: return "Web-Slinger"
        }
    }

    var blurb: String {
        self == .webSlinger ? "Rounded type with the Codex mascot mask." : "\(displayName) typography for the compact notch."
    }

    var theme: NotchTheme { NotchTheme.all[self] ?? .defaultTheme }
}

struct NotchTheme {
    let fontDesign: Font.Design
    var masksMascots = false

    func font(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: fontDesign)
    }

    static let defaultTheme = NotchTheme(fontDesign: .monospaced)
    static let aegisTheme = NotchTheme(fontDesign: .default)
    static let all: [NotchThemeID: NotchTheme] = [
        .aegis: .aegisTheme,
        .default: .defaultTheme,
        .glass: NotchTheme(fontDesign: .default),
        .pixel: NotchTheme(fontDesign: .monospaced),
        .terminal: NotchTheme(fontDesign: .monospaced),
        .brutalist: NotchTheme(fontDesign: .default),
        .webSlinger: NotchTheme(fontDesign: .rounded, masksMascots: true),
    ]
}

private struct NotchThemeKey: EnvironmentKey {
    static let defaultValue: NotchTheme = .aegisTheme
}

extension EnvironmentValues {
    var notchTheme: NotchTheme {
        get { self[NotchThemeKey.self] }
        set { self[NotchThemeKey.self] = newValue }
    }
}
