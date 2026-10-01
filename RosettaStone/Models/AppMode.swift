import Foundation

/// The two ways Rosetta Stone can run, selected by the **Run at Startup** toggle.
///
/// ## Mode A — `normal` (Run at Startup OFF; default and first install)
///
/// - Launches as an ordinary windowed app: the panel is shown, the Dock icon is visible.
/// - **No menu-bar icon** and nothing is kept alive in the background.
/// - URL-scheme actions are refused: the menu-bar gadget is what makes them reachable.
///
/// ## Mode B — `menuBarGadget` (Run at Startup ON; power-user mode)
///
/// - Launches **hidden**: no window at launch and no Dock icon
///   (`NSApp.setActivationPolicy(.accessory)`).
/// - The menu-bar icon is always present.
/// - **Left-click the icon toggles Gatekeeper directly** — no dropdown, no window.
/// - **Right-click the icon opens the full menu** (Open Main Window, Diagnostics…, Quit).
/// - All seven `rosettastone://` actions work, including cold starts.
/// - Switching the toggle OFF removes the login item, removes the icon and returns the
///   process to `normal` — see `AppDelegate.apply(_:)`.
///
/// The mode is a property of the **login item**, never of window visibility: the same
/// process moves between the two modes at runtime, without relaunching.
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
    ///    gadget, unconditionally. The login launch must never depend on a second read
    ///    of the plist.
    /// 2. **The LaunchAgent plist exists** → gadget. This is what makes a *manual*
    ///    launch while the toggle is ON behave exactly like the login launch: hidden
    ///    window, menu-bar icon, no Dock icon.
    /// 3. Otherwise → normal.
    ///
    /// After launch the mode is re-derived from `FeatureCoordinator.runAtStartup` on
    /// every change, so it cannot drift from the toggle. Kept Foundation-only and pure
    /// so it is testable without AppKit.
    static func resolve(menuBarOnlyArgument: Bool, launchAgentInstalled: Bool) -> AppMode {
        if menuBarOnlyArgument { return .menuBarGadget }
        return launchAgentInstalled ? .menuBarGadget : .normal
    }

    /// Human-readable label for `DiagnosticsPanel`.
    var displayName: String {
        switch self {
        case .normal:        return "normal app (Run at Startup off)"
        case .menuBarGadget: return "menu-bar gadget (Run at Startup on)"
        }
    }
}
