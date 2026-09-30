import SwiftUI

/// The ON/OFF pill switch from the mock-up.
///
/// Built from a `Button` rather than a SwiftUI `Toggle` for two reasons:
///
/// 1. **Availability.** The `Toggle(isOn:label:)` initialiser with a view-builder label
///    and `.accessibility(identifier:)` are macOS 11+ APIs. This app deploys to 10.15,
///    so they cannot be used.
/// 2. **Correctness.** A custom `ToggleStyle` that adds its own tap gesture to toggle the
///    value double-fires against the gesture `Toggle` installs itself. Rendering the pill
///    explicitly gives the app full control of the hit area.
///
/// The caption ("ON"/"OFF") also resolves the two *inverted* toggles (Gatekeeper, Hidden
/// Files) unambiguously: the switch shows what has actually been disabled, not a vague
/// "enabled".
struct PillSwitch: View {

    let isOn: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text(isOn ? "ON" : "OFF")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(isOn ? Color.white : Theme.primaryText)
            Circle()
                .fill(Color.white)
                .frame(width: 14, height: 14)
                .shadow(color: Color.black.opacity(0.25), radius: 1, y: 0.5)
        }
        .padding(.leading, isOn ? 8 : 5)
        .padding(.trailing, isOn ? 5 : 8)
        .frame(width: 54, height: 26)
        .background(Capsule().fill(isOn ? Theme.accentGreen : Theme.accentGrey))
    }
}

/// A compact spinner shown while a row's command is in flight.
///
/// Uses a trimmed circle rather than `ProgressView`, whose macOS styling changed between
/// Big Sur and Sequoia; drawing it keeps the panel stable on the whole support range.
struct BusySpinner: View {

    var size: CGFloat = 14

    @State private var isSpinning = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.72)
            .stroke(Theme.primaryText, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(isSpinning ? 360 : 0))
            .animation(Animation.linear(duration: 0.9).repeatForever(autoreverses: false),
                       value: isSpinning)
            .onAppear { isSpinning = true }
    }
}

/// The three Quick Tools buttons: an outlined pill matching the mock-up's bottom row.
struct QuickToolButtonStyle: ButtonStyle {

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(Theme.primaryText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.14 : 0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .stroke(Theme.buttonBorder, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
    }
}

/// The yellow "Install" button on the Rosetta 2 row.
struct AccentButtonStyle: ButtonStyle {

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(Theme.onAccentYellow)
            .padding(.horizontal, 30)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.accentYellow.opacity(configuration.isPressed ? 0.75 : 1))
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// The confirm button in the confirmation sheet.
///
/// `isDestructive` switches the fill to red so the risk is legible at the moment of the
/// click, not only in the body text of the dialog.
struct ConfirmButtonStyle: ButtonStyle {

    var isDestructive: Bool = false

    private var fill: Color {
        isDestructive ? Theme.failure : Theme.accentYellow
    }

    private var foreground: Color {
        isDestructive ? Color.white : Theme.onAccentYellow
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(foreground)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(fill.opacity(configuration.isPressed ? 0.75 : 1))
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// Small, non-blocking feedback line shown under the rows.
///
/// Every action ends in exactly one of success / cancelled / failed, so this never has to
/// guess: it only ever renders what the coordinator published.
struct StatusBanner: View {

    let message: FeatureCoordinator.StatusMessage

    private var color: Color {
        switch message.style {
        case .success: return Theme.success
        case .failure: return Theme.failure
        case .info:    return Theme.info
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(color)
                .frame(width: 3)
            Text(message.text)
                .font(.system(size: 11))
                .foregroundColor(color)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(color.opacity(0.12))
        )
    }
}
