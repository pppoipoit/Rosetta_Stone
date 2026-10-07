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

    // MARK: - Unified style registry (Phase 11)
    //
    // Every button, toggle and panel in the app resolves its lookups from here, so there is
    // exactly one definition of "what a primary button looks like". The style *types* still
    // live in `Components.swift`; this namespace is only the name they are reached by, which
    // is what keeps a look change to a single edit rather than a hunt through call sites.
    //
    // These are computed properties, not `static let`: a stored global of a mutable-shaped
    // type would be shared across every view that touched it, and a `ButtonStyle` carries
    // per-use state. Returning a fresh value each read keeps them inert and shareable.

    /// The panel's own background — a gradient, not a flat fill, matching the mock-up.
    static var panelBackground: LinearGradient {
        LinearGradient(
            gradient: Gradient(colors: [backgroundTop, backgroundBottom]),
            startPoint: .top,
            endPoint: .bottom)
    }

    /// The one accent the app leads with: the commit action (OK), the Rosetta Install
    /// button, and every affirmative control.
    static var accentColor: Color { accentYellow }

    /// The foreground that is legible **on** `accentColor`.
    static var onAccentColor: Color { onAccentYellow }

    /// Raised card fill, used by the mini panel's rows and the result dialog's list.
    static var panelSurface: Color { Color.white.opacity(0.05) }

    /// The destructive accent. Used for a critical confirm and for the "off" status dot.
    static var destructiveColor: Color { failure }

    /// **Master commit** — OK, Install, and every affirmative dialog button.
    static var primaryButton: AccentButtonStyle { AccentButtonStyle() }

    /// The master commit, in its destructive form (a critical confirmation).
    static var destructiveButton: ConfirmButtonStyle { ConfirmButtonStyle(isDestructive: true) }

    /// A neutral confirm (a non-destructive confirmation sheet's affirmative button).
    static var confirmButton: ConfirmButtonStyle { ConfirmButtonStyle(isDestructive: false) }

    /// **Master discard** — CANCEL, and the dismiss button on a sheet.
    static var secondaryButton: SecondaryButtonStyle { SecondaryButtonStyle() }

    /// The outlined Quick Tools pills.
    static var quickToolButton: QuickToolButtonStyle { QuickToolButtonStyle() }

    /// The quiet footer text link (Diagnostics).
    static var quietLinkButton: QuietLinkButtonStyle { QuietLinkButtonStyle() }

    /// The toggle's own palette and motion, so a pill cannot be drawn one colour in the
    /// panel and another in the mini panel.
    static var toggle: PillSwitchPalette { PillSwitchPalette() }
}

/// The ON/OFF pill's colours and animation, gathered in one value.
///
/// Exists so `PillSwitch` has no literals of its own: the pill is drawn from this struct in
/// both the main panel and the mini menu-bar panel, so the two cannot drift apart visually.
struct PillSwitchPalette {

    /// Track fill when the row is ON — the green from the mock-up.
    var trackOn: Color { Theme.accentGreen }

    /// Track fill when the row is OFF.
    var trackOff: Color { Theme.accentGrey }

    /// The knob, always white: it has to read against both a green and a grey track.
    var knob: Color { .white }

    /// Duration and curve of the slide. 0.2 s ease-in-out reads as "it moved" rather than
    /// "it blinked" — long enough to see the direction, short enough not to lag the click.
    var animation: Animation { .easeInOut(duration: 0.2) }

    /// The track colour for a state. One switch so the ON and OFF colours can never be
    /// paired with the wrong caption.
    func track(isOn: Bool) -> Color { isOn ? trackOn : trackOff }

    /// The ON/OFF caption colour. White in **both** states, because the caption is drawn
    /// *on* the coloured track — using the panel's grey text here would make the label
    /// vanish into the OFF pill.
    func caption(isOn: Bool) -> Color { .white }
}

extension View {
    /// Sets the AppKit tooltip and the VoiceOver label for a control in one modifier.
    ///
    /// Wrapped rather than used inline because SwiftUI's `.help(_:)` and
    /// `.accessibilityLabel(_:)` are both **macOS 11+**, and this app deploys to 10.15.
    /// `TooltipHost` already solves this for arbitrary content; this is the shorthand for the
    /// common "leaf control that just wants a tooltip" case. The `content` generic is `Self`,
    /// so the wrapped view keeps its own identity and nothing else about it changes.
    func accessibilityTitle(_ text: String) -> some View {
        TooltipHost(text: text, content: self)
    }
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
