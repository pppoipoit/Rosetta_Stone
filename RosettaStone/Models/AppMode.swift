import Foundation

/// The two ways Rosetta Stone can run, selected by the **Run at Startup** toggle.
///
/// ## Mode A — `normal` (Run at Startup OFF; default and first install)
///
/// - Launches as an ordinary windowed app: the panel is shown, the Dock icon is visible.
/// - **No menu-bar icon** and nothing is kept alive in the background.
///
/// ## Mode B — `menuBarGadget` (Run at Startup ON; power-user mode)
///
/// - Launches **hidden**: no window at launch and no Dock icon
///   (`NSApp.setActivationPolicy(.accessory)`).
/// - The menu-bar icon is always present.
/// - **Left-click the icon opens the mini panel** — the three switches people reach for,
///   staged and committed exactly like the main panel.
/// - **Right-click the icon opens the full menu** (Open Main Window, Diagnostics…, Quit).
/// - Switching the toggle OFF removes the login item, removes the icon and returns the
///   process to `normal` — see `AppDelegate.apply(_:)`.
///
/// The mode is a property of the **launch**, never of the plist's existence: the same
/// process moves between the two modes at runtime, without relaunching.
///
/// ## Why a manual launch is *always* the normal app
///
/// Phase-6 audit, P0. The old rule was "plist exists → gadget", which made a manual
/// double-click produce the **invisible app**: `Info.plist` carries `LSUIElement = true`
/// for the gadget posture, mode B skips the main window, and mode A never installs a status
/// item — so the process was alive with *nothing* on screen and no Dock tile to click.
/// The user then had no way to open the app at all.
///
/// The rule is now one signal, and only one:
///
/// | Launch | Signal | Mode |
/// |--------|--------|------|
/// | Login item (LaunchAgent) | `--menu-bar-only` is in `CommandLine.arguments` | `.menuBarGadget` |
/// | Anything else (double-click, Dock, `open`, Spotlight, `open -a`) | flag absent | `.normal` |
///
/// The plist is still the source of truth for the **Run at Startup toggle** and for the
/// live mode switch (`AppDelegate.apply(_:)`), and it still decides the *next* login's
/// posture — it simply must not decide the posture of the launch the user performed.
enum AppMode: String {

    /// Run at Startup OFF — a normal windowed app with a Dock icon and no menu-bar icon.
    case normal

    /// Run at Startup ON — a background menu-bar gadget with no Dock icon.
    case menuBarGadget

    /// Resolves the mode at launch.
    ///
    /// Resolution order, and why:
    ///
    /// 1. **`--menu-bar-only`** (written into the LaunchAgent by `StartupManager`) →
    ///    gadget, unconditionally. This is the *only* signal that can produce the hidden
    ///    posture, so a manual launch can never be swallowed by it.
    /// 2. **Anything else** → normal. This includes a double-click while the Run at Startup
    ///    toggle is ON and the plist is sitting in `~/Library/LaunchAgents`. The user asked
    ///    for a window; they get a window and a Dock icon, and the gadget keeps running
    ///    from its own login item.
    ///
    /// - Parameter menuBarOnlyArgument: `AppDelegate.requestedMenuBarOnly()` in production.
    /// - Parameter launchAgentInstalled: **accepted and deliberately ignored.** Kept in the
    ///   signature so every call site has to confront the decision rather than silently
    ///   inheriting the old behaviour, and so the Diagnostics/legacy call shape does not
    ///   break. The plist governs the toggle and the next login, never this launch.
    static func resolve(menuBarOnlyArgument: Bool,
                        launchAgentInstalled: Bool) -> AppMode {
        _ = launchAgentInstalled // see the doc comment: manual launch is always `.normal`.
        return menuBarOnlyArgument ? .menuBarGadget : .normal
    }

    /// Human-readable label for `DiagnosticsPanel`.
    ///
    /// Describes the **posture**, not the toggle: a manual launch of a build with the login
    /// item installed is `normal` while the plist exists, and the Diagnostics row for the
    /// login item already reports that separately.
    var displayName: String {
        switch self {
        case .normal:        return "normal app (window + Dock icon)"
        case .menuBarGadget: return "menu-bar gadget (hidden — login item launch)"
        }
    }
}
