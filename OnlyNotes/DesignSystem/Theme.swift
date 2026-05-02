import SwiftUI

// MARK: - Adaptive Palette

extension Color {
    // Backgrounds
    static var onPaper: Color {
        Color(light: Color(red: 0.98, green: 0.97, blue: 0.95),
              dark:  Color(red: 0.10, green: 0.10, blue: 0.11))
    }
    static var onPanel: Color {
        Color(light: Color(red: 0.94, green: 0.93, blue: 0.91),
              dark:  Color(red: 0.13, green: 0.13, blue: 0.14))
    }
    static var onRaised: Color {
        Color(light: .white,
              dark:  Color(red: 0.17, green: 0.17, blue: 0.18))
    }
    static var onSeparator: Color {
        Color(light: Color(red: 0.85, green: 0.84, blue: 0.82),
              dark:  Color(red: 0.22, green: 0.22, blue: 0.23))
    }

    // Text
    static var onInk: Color {
        Color(light: Color(red: 0.13, green: 0.12, blue: 0.11),
              dark:  Color(red: 0.93, green: 0.92, blue: 0.90))
    }
    static var onMutedInk: Color {
        Color(light: Color(red: 0.45, green: 0.43, blue: 0.40),
              dark:  Color(red: 0.55, green: 0.54, blue: 0.52))
    }
    static var onFaintInk: Color {
        Color(light: Color(red: 0.70, green: 0.68, blue: 0.65),
              dark:  Color(red: 0.38, green: 0.37, blue: 0.36))
    }

    // Accent — warm teal
    static var onAccent: Color {
        Color(light: Color(red: 0.13, green: 0.55, blue: 0.52),
              dark:  Color(red: 0.25, green: 0.72, blue: 0.68))
    }

    // Recording
    static var onRecordIdle: Color { onMutedInk }
    static var onRecordActive: Color { Color(red: 0.92, green: 0.26, blue: 0.21) }
}

// MARK: - Light/Dark initializer

extension Color {
    init(light: Color, dark: Color) {
        self.init(NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(dark) : NSColor(light)
        })
    }
}

// MARK: - Typography

extension Font {
    static var onDisplay: Font    { .system(.largeTitle, design: .serif).weight(.semibold) }
    static var onTitle: Font      { .system(.title2, design: .serif).weight(.semibold) }
    static var onHeadline: Font   { .system(.headline, design: .default) }
    static var onBody: Font       { .system(.body, design: .default) }
    static var onCaption: Font    { .system(.caption, design: .default) }
    static var onMeta: Font       { .system(.caption, design: .monospaced) }
    static var onMono: Font       { .system(.body, design: .monospaced) }
}

// MARK: - Spacing

enum Spacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 16
    static let lg: CGFloat = 24
    static let xl: CGFloat = 40
}

// MARK: - Appearance mode

enum AppearanceMode: String, CaseIterable {
    case system = "System"
    case light  = "Light"
    case dark   = "Dark"

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}
