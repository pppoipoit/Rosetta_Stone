import SwiftUI
import AppKit

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

/// A tooltip attached to a real `NSView`.
///
/// SwiftUI's `.help(_:)` is **macOS 11+**, and this app deploys to 10.15, so the tooltip is
/// put on AppKit instead. Used for locked rows (see `FeatureAvailability.tooltip`), where a
/// `.disabled(true)` row would otherwise give the user nothing to hover for.
struct TooltipHost<Content: View>: NSViewRepresentable {

    /// Tooltip text. Empty means "no tooltip" — AppKit shows nothing.
    let text: String

    /// The SwiftUI content to host.
    let content: Content

    func makeNSView(context: Context) -> NSView {
        let container = NSView(frame: .zero)
        container.toolTip = text.isEmpty ? nil : text

        let hosting = NSHostingView(rootView: content)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // The lock state can change at runtime (a state reload), so the tooltip is refreshed
        // rather than set once at creation.
        nsView.toolTip = text.isEmpty ? nil : text
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

/// A small, quiet text button: the panel footer's **Diagnostics…** link.
///
/// Deliberately not a pill: it is a support affordance, not a feature, but it must stay
/// visible because mode A has no menu-bar icon and therefore no other route to it.
struct QuietLinkButtonStyle: ButtonStyle {

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(Theme.info.opacity(configuration.isPressed ? 0.55 : 0.9))
            .contentShape(Rectangle())
    }
}

/// The orange dot that marks a row as **staged but not yet applied** (ADR-009).
///
/// Drawn as a `Circle` rather than a text bullet so it is a crisp dot at every scale and
/// carries no font dependency. Its meaning is "this row differs from the system right now",
/// which is exactly the pending-vs-actual comparison `ContentView` makes.
struct PendingDot: View {

    var size: CGFloat = 7

    var body: some View {
        Circle()
            .fill(Theme.pending)
            .frame(width: size, height: size)
            // A faint halo so the dot stays legible against both gradient ends.
            .shadow(color: Theme.pending.opacity(0.55), radius: 2)
            // No `.accessibilityIdentifier(_:)` here: that modifier is **macOS 11+** and this
            // app deploys to 10.15, so naming it would fail to compile against the floor. The
            // dot is decorative — the pending state it marks is also announced by the Apply
            // button's count and the status banner — so it needs no accessibility element.
    }
}

/// The two master buttons that commit or discard the queue.
///
/// Disabled while the queue is empty, so they cannot be pressed into a no-op — and so the
/// panel teaches the rule by showing that Apply is unavailable until something is staged.
struct ApplyBar: View {

    /// Number of staged rows, shown as the count on the Apply button.
    let pendingCount: Int

    /// True while a batch is in flight. Greys out both buttons.
    let isBusy: Bool

    let onCancel: () -> Void
    let onApply: () -> Void

    private var isDisabled: Bool { pendingCount == 0 || isBusy }

    var body: some View {
        HStack(spacing: 10) {
            Button("❌ ยกเลิก") { onCancel() }
                .buttonStyle(SecondaryButtonStyle())
                .frame(maxWidth: .infinity)
                .disabled(isDisabled)

            Button(applyTitle) { onApply() }
                .buttonStyle(AccentButtonStyle())
                .frame(maxWidth: .infinity)
                .disabled(isDisabled)
                // ⌘↩ applies the queue. `keyboardShortcut` is macOS 10.15+, so it is safe on
                // the deployment floor; the modifiers overload is macOS 11+, which is why the
                // `.return`-only form is used via the availability-checked helper below.
                .modifier(ConditionalCommandReturnShortcut())
        }
        .opacity(isDisabled ? 0.45 : 1)
        .padding(.top, 12)
    }

    private var applyTitle: String {
        pendingCount == 1 ? "✅ ตกลง (1)" : "✅ ตกลง (\(pendingCount))"
    }
}

/// Applies ⌘↩ as the Apply shortcut on **macOS 11 and newer**.
///
/// ## Why the two-type split
///
/// `keyboardShortcut` is macOS 11+ in this SDK — *both* overloads, including the
/// single-argument one. There is therefore no SwiftUI keyboard-shortcut API at all on the
/// 10.15 floor, so the 10.15 branch below deliberately applies **no** shortcut rather than
/// reaching for one that does not exist.
///
/// The availability requirement lives on `CommandReturnShortcut`'s own declaration and is
/// **not** written as `if #available` inside a single `body`. That is deliberate: an
/// `if #available` inside a `@ViewBuilder` loses its narrowing, because `buildEither(first:second:)`
/// is not itself guarded, and the compiler then rejects the 11+ API as unreachable-by-guard.
/// Selecting between two *types* — each carrying its own `@available` — is the pattern that
/// actually holds.
struct ConditionalCommandReturnShortcut: ViewModifier {

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 11.0, *) {
            content.modifier(CommandReturnShortcut())
        } else {
            content
        }
    }
}

/// The ⌘↩ binding itself, isolated behind its availability so the 11+ API is only ever named
/// inside a guarded branch.
@available(macOS 11.0, *)
private struct CommandReturnShortcut: ViewModifier {

    func body(content: Content) -> some View {
        content.keyboardShortcut(.return, modifiers: .command)
    }
}

/// A quiet, outlined button — used for the master **Cancel** action.
///
/// Deliberately not a pill: it is the destructive half of the pair, and its outline keeps it
/// visually subordinate to the accent Apply button next to it.
struct SecondaryButtonStyle: ButtonStyle {

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(Theme.primaryText)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.14 : 0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Theme.buttonBorder, lineWidth: 1)
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
