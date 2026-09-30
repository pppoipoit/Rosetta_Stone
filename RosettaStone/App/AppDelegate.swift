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

    /// Set once the UI is ready. URL actions are queued against this rather than being
    /// dropped — see `handle(urls:)`.
    private var isReady = false

    /// URLs that arrived before the delegate finished setting up.
    ///
    /// This is the fix for the cold-start Shortcuts bug. Launch Services delivers
    /// `application(_:open:)` on a **cold start** while the app is still launching; the
    /// previous code re-dispatched exactly once on the next runloop turn and silently
    /// discarded the URL if the presenter was not up yet. A queue cannot lose a URL, and
    /// cannot spin either: `drainPendingURLs()` is only reached once `isReady` is true.
    private var pendingURLs: [URL] = []

    /// `true` when LaunchAgent started us with `--menu-bar-only`.
    ///
    /// In that mode the app must be a menu-bar gadget *only*: no window is created at
    /// all, and not even the first-run window appears. The status item is the entire UI.
    let menuBarOnly: Bool

    /// `UserDefaults` key marking that the app has been shown a window at least once.
    ///
    /// Absent == first run. Internal rather than private so `DiagnosticsPanel` can report
    /// the flag's state without duplicating the string literal.
    static let hasLaunchedOnceKey = "hasLaunchedOnce"

    // MARK: - Init

    /// - Parameter menuBarOnly: forces menu-bar-only posture, overriding the argument
    ///   scan. Exists so the mode is testable without mutating `CommandLine`.
    init(menuBarOnly: Bool? = nil) {
        self.menuBarOnly = menuBarOnly ?? AppDelegate.requestedMenuBarOnly()
        super.init()
    }

    /// `true` when `--menu-bar-only` appears anywhere in the process arguments.
    ///
    /// `StartupManager.makePlist` writes exactly this flag, so the LaunchAgent launch
    /// path and the normal user double-click path share one implementation.
    static func requestedMenuBarOnly() -> Bool {
        CommandLine.arguments.contains("--menu-bar-only")
    }

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        Trace.logLaunchContext()
        Trace.log("launch didFinishLaunching menuBarOnly=\(menuBarOnly)")

        // Agent app: no Dock icon, no app menu. Set *before* the status item exists so
        // there is no window of time in which a Dock tile can appear, then re-asserted
        // after the UI is built. Info.plist already says `LSUIElement = true`; this is
        // the runtime guarantee that the posture holds even if the plist is wrong.
        NSApp.setActivationPolicy(.accessory)

        // The status item is created on the MAIN thread, synchronously, here — never
        // later and never off-main. AppKit status items created off the main thread do
        // not reliably appear, and creating one lazily on first click is exactly how the
        // macOS 26 "process alive, nothing on screen" report happens.
        assert(Thread.isMainThread, "status item must be installed on the main thread")
        let controller = MenuBarController(coordinator: coordinator,
                                           menuBarOnly: menuBarOnly)
        menuBarController = controller
        isReady = true
        NSApp.setActivationPolicy(.accessory)

        // Unprivileged state read: opening the app must never cost a password prompt.
        coordinator.loadState()

        let autoBoot = coordinator.availability(for: .autoBoot).isEnabled ? "available" : "locked"
        let rosetta = coordinator.availability(for: .rosetta2).isEnabled ? "available" : "locked"
        Trace.log("launch started arch=\(coordinator.architecture.displayName) "
            + "macOS=\(Trace.osVersionText()) AutoBoot=\(autoBoot) Rosetta2=\(rosetta)")

        // A cold start caused by Launch Services delivers the URL *after* this method
        // returns, so `application(_:open:)` handles it. Deliberately no window is shown:
        // the caller asked for an action, not for a window (`docs/ARCHITECTURE.md` §3).
        //
        // Only now that the presenter exists is it safe to run anything that was queued.
        drainPendingURLs()

        // First run must never look like a dead app: `LSUIElement` means no Dock icon, so
        // a user who has not yet seen the panel would have *no* way to tell that anything
        // launched. Show the panel once and record it.
        presentFirstRunWindowIfNeeded()
    }

    /// Shows the panel the very first time the app is launched by hand.
    ///
    /// Skipped in `--menu-bar-only` mode (the startup gadget must stay window-free) and
    /// when a URL action was queued (that caller asked for an action, not a window —
    /// although `open-app` will show it regardless, via the router).
    private func presentFirstRunWindowIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: AppDelegate.hasLaunchedOnceKey) == nil else {
            Trace.log("firstRun skipped: hasLaunchedOnce already set")
            return
        }

        // Set the flag *before* showing, so a user who closes the panel immediately still
        // does not get it shoved back in their face on the next launch.
        defaults.set(true, forKey: AppDelegate.hasLaunchedOnceKey)
        defaults.synchronize()

        guard !menuBarOnly else {
            Trace.log("firstRun window suppressed: --menu-bar-only")
            return
        }
        guard pendingURLs.isEmpty else {
            Trace.log("firstRun window suppressed: a URL action is pending")
            return
        }

        Trace.log("firstRun showing main window")
        menuBarController?.showMainWindow()
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
    /// The process is never terminated and relaunched to handle a URL — which is what
    /// makes a Shortcut work **cold**, with the app not running at all.
    func application(_ application: NSApplication, open urls: [URL]) {
        Trace.log("url delivered count=\(urls.count) "
            + urls.map(\.absoluteString).joined(separator: ","))
        handle(urls: urls)
    }

    /// Routes URLs now, or queues them until the presenter is ready.
    ///
    /// The queue is what guarantees all seven Shortcuts actions work on a cold start: the
    /// URL can legally arrive before `applicationDidFinishLaunching` has built the status
    /// item, and losing it would silently do nothing for the user.
    func handle(urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard isReady, let presenter = menuBarController else {
            Trace.log("url queued count=\(urls.count) (presenter not ready yet)")
            pendingURLs.append(contentsOf: urls)
            return
        }
        // `MenuBarController` is the presenter: it owns the window and raises the sheet.
        for url in urls {
            URLActionRouter.route(url, coordinator: coordinator, presenter: presenter)
        }
    }

    /// Executes everything queued during launch. Called once `isReady` is true.
    private func drainPendingURLs() {
        guard !pendingURLs.isEmpty else { return }
        let queued = pendingURLs
        pendingURLs.removeAll()
        // Re-checked rather than assumed: the drain must not be able to recurse.
        guard isReady, let presenter = menuBarController else {
            pendingURLs = queued
            return
        }
        Trace.log("url draining \(queued.count) queued action(s)")
        for url in queued {
            URLActionRouter.route(url, coordinator: coordinator, presenter: presenter)
        }
    }
}
