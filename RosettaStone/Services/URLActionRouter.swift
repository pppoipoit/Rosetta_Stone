import Foundation

/// Validates and dispatches `rosettastone://` URLs.
///
/// A custom URL scheme is used instead of App Intents, which requires macOS 13+ and
/// would break the 10.15 floor (ADR-002). In mode B (Run at Startup ON) it is also the
/// app's only activation path, because the menu-bar gadget has no Dock icon to click;
/// in mode A the URLs are refused (see `AppDelegate.handle(urls:)`).
///
/// ## Registered actions
///
/// | URL                            | Behaviour                     | Elevation |
/// |--------------------------------|-------------------------------|-----------|
/// | `rosettastone://open-app`      | Show and focus the panel      | No        |
/// | `rosettastone://toggle-gatekeeper` | Flip feature 2            | admin     |
/// | `rosettastone://toggle-hidden-files` | Flip feature 3          | No        |
/// | `rosettastone://flush-dns`     | Feature 7                      | admin     |
/// | `rosettastone://rebuild-spotlight` | Feature 6                 | admin     |
/// | `rosettastone://clear-cache`   | Feature 8 — still confirms    | admin     |
/// | `rosettastone://install-rosetta` | Feature 5                    | admin     |
///
/// There is deliberately **no** URL action for `run-at-startup` or `auto-boot`: both
/// change boot/login behaviour, and driving them from an untrusted caller with no
/// in-app confirmation would be unsafe.
enum URLAction {

    /// Every action, keyed by its `rawValue`, which is the URL's **host** component.
    enum Kind: String, CaseIterable {
        case openApp            = "open-app"
        case toggleGatekeeper   = "toggle-gatekeeper"
        case toggleHiddenFiles  = "toggle-hidden-files"
        case flushDNS           = "flush-dns"
        case rebuildSpotlight   = "rebuild-spotlight"
        case clearCache         = "clear-cache"
        case installRosetta     = "install-rosetta"
    }

    /// Extracts the action from a URL, or `nil` if it is not one of ours.
    ///
    /// Rules from `docs/ARCHITECTURE.md` §3:
    /// - the action is the **host** component (`rosettastone://flush-dns` → `flush-dns`),
    /// - matching is case-insensitive but **never prefix-matched**, so
    ///   `rosettastone://flush-dns-extra` is rejected rather than half-applied,
    /// - query and path components are ignored (`?force=1` is discarded, not honoured),
    /// - a malformed URL is rejected without any user-facing error.
    static func kind(for url: URL) -> Kind? {
        guard url.scheme?.lowercased() == "rosettastone" else { return nil }
        guard let host = url.host?.lowercased(), host.isEmpty == false else { return nil }
        return Kind(rawValue: host)
    }
}

/// The side effects a `URLAction` may have: show the panel, or run a feature.
///
/// Declared as a protocol so the router stays testable and the AppKit layer does not
/// leak into routing logic.
protocol URLActionHandling: AnyObject {
    /// Shows and focuses the main window.
    func showMainWindow()
    /// Confirms with the user, then runs `action`. Used for the destructive action.
    func performDestructiveAction(_ title: String, message: String, action: @escaping () -> Void)
}

/// Validates URLs and forwards them to the coordinator.
///
/// Unknown actions are logged and discarded — a Shortcut firing at 3 a.m. must never
/// produce an alert the user did not ask for.
enum URLActionRouter {

    /// Shown when a URL action arrives in mode A (Run at Startup OFF).
    ///
    /// URL actions are the menu-bar gadget's surface. The normal app refuses them
    /// explicitly — with one quiet footer message — rather than appearing to do nothing
    /// or silently performing a privileged action.
    static let normalModeRefusalMessage =
        "URL actions (rosettastone://) work only when Run at Startup is ON — "
        + "turn it on to switch to menu-bar gadget mode."

    /// Routes one URL. Must be called on the main thread.
    static func route(_ url: URL,
                      coordinator: FeatureCoordinator,
                      presenter: URLActionHandling) {
        guard let kind = URLAction.kind(for: url) else {
            NSLog("[RosettaStone] ignoring unrecognised URL: %@", url.absoluteString)
            return
        }

        switch kind {
        case .openApp:
            presenter.showMainWindow()

        case .toggleGatekeeper:
            // Toggle semantics: read reality, then write the opposite. The read happens
            // inside the locked operation, so the pair is atomic with respect to every
            // other operation — see `toggleGatekeeper()`.
            coordinator.toggleGatekeeper()

        case .toggleHiddenFiles:
            coordinator.toggleHiddenFiles()

        case .flushDNS:
            coordinator.flushDNS()

        case .rebuildSpotlight:
            coordinator.rebuildSpotlight()

        case .installRosetta:
            coordinator.installRosetta()

        case .clearCache:
            // Feature 8 keeps its confirmation even when URL-driven — and the same Thai +
            // English warning as the panel and the menu, from one constant.
            presenter.performDestructiveAction(
                "Clear the system cache?",
                message: FeatureID.clearSystemCacheWarning,
                action: { coordinator.clearSystemCache() }
            )
        }
    }
}
