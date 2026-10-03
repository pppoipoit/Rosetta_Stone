import SwiftUI

/// Colours, metrics and reusable chrome for the dark panel.
///
/// The palette is defined explicitly rather than taken from semantic system colours so
/// the panel looks identical on macOS 10.15 and on macOS 27 — where system accent colours
/// and materials have changed several times.
enum Theme {

    // MARK: - Backgrounds

    /// Top of the panel gradient — the dark slate behind the title.
    static let backgroundTop = Color(red: 0.11, green: 0.12, blue: 0.14)

    /// Bottom of the panel gradient — slightly lighter, matching the mock-up.
    static let backgroundBottom = Color(red: 0.15, green: 0.16, blue: 0.18)

    /// Hairline separator between rows.
    static let separator = Color.white.opacity(0.07)

    // MARK: - Text

    static let title = Color(red: 0.96, green: 0.96, blue: 0.97)
    static let primaryText = Color(red: 0.92, green: 0.93, blue: 0.94)
    static let secondaryText = Color(red: 0.55, green: 0.57, blue: 0.60)

    // MARK: - Accents

    /// The green "ON" pill in the mock-up.
    static let accentGreen = Color(red: 0.20, green: 0.78, blue: 0.44)

    /// The grey "OFF" pill.
    static let accentGrey = Color(red: 0.55, green: 0.57, blue: 0.60)

    /// The yellow "Install" button in the mock-up.
    static let accentYellow = Color(red: 1.00, green: 0.82, blue: 0.16)
    static let onAccentYellow = Color(red: 0.11, green: 0.12, blue: 0.14)

    /// Outline for the outlined Quick Tools buttons.
    static let buttonBorder = Color.white.opacity(0.18)

    /// Feedback colours for the footer banner.
    static let success = Color(red: 0.30, green: 0.82, blue: 0.47)
    static let failure = Color(red: 0.95, green: 0.42, blue: 0.42)
    static let info = Color(red: 0.55, green: 0.72, blue: 0.95)
    static let warning = Color(red: 1.00, green: 0.76, blue: 0.30)

    /// The orange dot marking a row whose staged value differs from the system (ADR-009).
    ///
    /// Orange rather than the accent yellow so it never reads as the yellow **Install** button
    /// on the Rosetta 2 row — the dot and that button sit on the same panel.
    static let pending = Color(red: 1.00, green: 0.65, blue: 0.20)

    // MARK: - Metrics

    static let rowSpacing: CGFloat = 34
    static let contentPadding: CGFloat = 28
}

/// A hairline separator used between rows, matching the mock-up's subtle rule.
struct RowSeparator: View {
    var body: some View {
        Rectangle()
            .fill(Theme.separator)
            .frame(height: 1)
            .padding(.leading, Theme.contentPadding)
            .padding(.trailing, Theme.contentPadding)
    }
}

/// A padlock drawn as text-free vector art, used on CPU-locked rows.
///
/// SF Symbols are macOS 11+, so the lock is drawn with shapes instead of
/// `Image(systemName: "lock.fill")` to keep the 10.15 floor. The same rule applies to
/// every icon in this app — none of them use SF Symbols.
struct LockIcon: View {

    var size: CGFloat = 14

    var body: some View {
        ZStack {
            // Shackle
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .strokeBorder(Theme.accentGrey, lineWidth: max(1.5, size * 0.12))
                .frame(width: size * 0.52, height: size * 0.46)
                .offset(y: -size * 0.18)
            // Body
            RoundedRectangle(cornerRadius: size * 0.18, style: .continuous)
                .fill(Theme.accentGrey)
                .frame(width: size * 0.78, height: size * 0.5)
                .offset(y: size * 0.19)
        }
        .frame(width: size, height: size)
    }
}
