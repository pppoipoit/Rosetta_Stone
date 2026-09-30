import AppKit
import Combine

/// The application delegate — the app's real entry point on every supported OS version.
///
/// `LSUIElement = true` in `Info.plist` makes the process an agent: no Dock icon, no app
/// menu, no window at launch. `NSApp.setActivationPolicy(.accessory)` is the runtime
/// equivalent and is set defensively here as well (`docs/ARCHITECTURE.md` §1).
///
/// ## Why a delegate rather than pure SwiftUI
///
/// `MenuBarExtra` needs macOS 13 and `onOpenURL` needs macOS 11, but the deployment floor
/// is 10.15. So the status item, the window and URL delivery all live in AppKit; the
/// panel's *contents* are SwiftUI, hosted in an `NSHostingView`. `RosettaStoneApp`
/// provides the SwiftUI `App` entry point on macOS 11+ and `main.swift` falls back to
/// this delegate on 10.15 — both funnel into the same delegate, so there is only ever
/// one code path for behaviour.
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Observable state shared by the window and the menu-bar menu.
    let coordinator = FeatureCoordinator()

    /// Owns the `NSStatusItem` and the panel window.
    private(set) var menuBarController: MenuBarController?

    /// Set once the UI is ready. URL actions that only need the coordinator can arrive
    /// before this, so they are guarded rather than assumed.
    private var isReady = false

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Agent app: no Dock icon, no app menu. Defensive — Info.plist already says so.
        NSApp.setActivationPolicy(.accessory)

        let controller = MenuBarController(coordinator: coordinator)
        menuBarController = controller
        isReady = true

        // Unprivileged state read: opening the app must never cost a password prompt.
        coordinator.loadState()

        let autoBoot = coordinator.availability(for: .autoBoot).isEnabled ? "available" : "locked"
        let rosetta = coordinator.availability(for: .rosetta2).isEnabled ? "available" : "locked"
        NSLog("[RosettaStone] started on \(coordinator.architecture.displayName); "
            + "Auto Boot \(autoBoot), Rosetta 2 \(rosetta).")

        // A cold start caused by Launch Services delivers the URL *after* this method
        // returns, so `application(_:open:)` handles it. Deliberately no window is shown:
        // the caller asked for an action, not for a window (`docs/ARCHITECTURE.md` §3).
    }

    /// Closing the panel must not quit the app — the menu-bar icon is the app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - URL scheme

    /// Handles `rosettastone://…` delivered by Launch Services.
    ///
    /// This is also the app's activation path: with `LSUIElement` there is no Dock icon
    /// to click, so Launch Services is how a running instance gets asked to do something.
    /// The process is never terminated and relaunched to handle a URL.
    func application(_ application: NSApplication, open urls: [URL]) {
        handle(urls: urls)
    }

    func handle(urls: [URL]) {
        guard isReady, let presenter = menuBarController else {
            // The UI is not up yet — re-deliver on the next runloop turn. `isReady` is set
            // in `applicationDidFinishLaunching`, which always precedes any URL delivery,
            // so this defers at most one turn and cannot spin.
            DispatchQueue.main.async { [weak self] in self?.handle(urls: urls) }
            return
        }
        // `MenuBarController` is the presenter: it owns the window and raises the sheet.
        for url in urls {
            URLActionRouter.route(url, coordinator: coordinator, presenter: presenter)
        }
    }
}
