import AppKit
import SwiftUI

/// Design tokens. Warm paper neutrals, editorial type (a serif for titles
/// and dates, the system sans for everything you read or click) and soft
/// raised surfaces, after the Dia browser; one restrained accent.
enum Theme {
    // MARK: Colors

    static let bg = adaptive(light: 0xFCFBF8, dark: 0x161513)
    static let sidebar = adaptive(light: 0xF4F2ED, dark: 0x1B1A18)
    static let surface = adaptive(light: 0xFFFFFF, dark: 0x201F1C)
    static let surfaceRaised = adaptive(light: 0xF3F1EC, dark: 0x252421)
    static let surfaceHover = adaptive(light: 0xECE9E3, dark: 0x2C2B28)
    static let border = adaptive(light: 0xE8E5DE, dark: 0x2E2D2A)
    static let borderStrong = adaptive(light: 0xD8D4CB, dark: 0x3C3B37)

    static let text = adaptive(light: 0x23221F, dark: 0xECEAE4)
    static let textSecondary = adaptive(light: 0x6F6C65, dark: 0xA3A099)
    static let textTertiary = adaptive(light: 0xA39F96, dark: 0x6F6C66)

    static let accent = adaptive(light: 0x3E6BD6, dark: 0x86A6F5)
    static let accentSoft = adaptive(light: 0xEBEFF9, dark: 0x1F2537)
    static let recording = adaptive(light: 0xE5484D, dark: 0xFF6369)
    static let success = adaptive(light: 0x2F8F5B, dark: 0x58C48E)
    static let warning = adaptive(light: 0xB7740F, dark: 0xF0B44C)

    /// Speaker palette. Muted so a transcript with many speakers stays calm.
    static let speakerColors: [Color] = [
        adaptive(light: 0x3E6BD6, dark: 0x86A6F5),
        adaptive(light: 0xB8501C, dark: 0xF2A070),
        adaptive(light: 0x2F8F5B, dark: 0x6BD49B),
        adaptive(light: 0x6E55C9, dark: 0xB4A0F5),
        adaptive(light: 0xA36A12, dark: 0xE6C06A),
        adaptive(light: 0x16778C, dark: 0x5CC8DB),
        adaptive(light: 0xB0336A, dark: 0xF08FB8),
        adaptive(light: 0x55791C, dark: 0xA8D86B),
    ]

    static func speakerColor(_ index: Int) -> Color {
        speakerColors[((index % speakerColors.count) + speakerColors.count) % speakerColors.count]
    }

    // MARK: Type

    /// New York, the system serif: dates and meeting titles.
    static let displayFont = Font.system(size: 28, weight: .regular, design: .serif)
    static let serifTitleFont = Font.system(size: 22, weight: .regular, design: .serif)
    static let serifSmallFont = Font.system(size: 15, weight: .regular, design: .serif)
    static let titleFont = Font.system(size: 15, weight: .semibold)
    static let headingFont = Font.system(size: 13, weight: .semibold)
    static let readingFont = Font.system(size: 14)
    static let bodyFont = Font.system(size: 13)
    static let smallFont = Font.system(size: 12)
    static let captionFont = Font.system(size: 11)
    static let monoFont = Font.system(size: 11, design: .monospaced)
    static let monoSmallFont = Font.system(size: 10.5, design: .monospaced)

    // MARK: Metrics

    static let radiusLarge: CGFloat = 14
    static let radius: CGFloat = 10
    static let radiusSmall: CGFloat = 7
    static let hairline: CGFloat = 1

    // MARK: Motion

    /// One set of curves for every animation, so the app moves with one feel.
    /// Views pass `reduceMotion` (the accessibility setting) to fall back to
    /// plain fades.
    enum Motion {
        /// Selection pills sliding, rows reacting: quick, barely any overshoot.
        static let snappy = Animation.spring(response: 0.32, dampingFraction: 0.84)
        /// Panels and cards opening.
        static let gentle = Animation.spring(response: 0.42, dampingFraction: 0.86)
        /// Hover tints and small fades.
        static let quick = Animation.easeOut(duration: 0.14)

        static func snappy(_ reduceMotion: Bool) -> Animation { reduceMotion ? .easeOut(duration: 0.12) : snappy }
        static func gentle(_ reduceMotion: Bool) -> Animation { reduceMotion ? .easeOut(duration: 0.15) : gentle }
    }

    // MARK: Helpers

    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua, .vibrantDark, .vibrantLight]).map {
                $0 == .darkAqua || $0 == .vibrantDark
            } ?? false
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}
