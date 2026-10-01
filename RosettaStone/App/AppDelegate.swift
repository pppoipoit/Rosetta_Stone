import AppKit
import Combine

/// The application delegate — the app's real entry point on every supported OS version.
///
/// ## Two modes, one process
///
/// The **Run at Startup** toggle chooses the app's entire posture (`AppMode`):
///
/// | Mode | Toggle | Launch | Dock icon | Menu-bar icon | URL actions |
/// |------|--------|--------|-----------|---------------|-------------|
/// | A — normal | OFF (default) | window shown | yes | no | refused |
/// | B — gadget | ON | window hidden | no (`LSUIElement`) | always | all seven work |
///
/// The mode is *re-derived from reality* — `FeatureCoordinator.runAtStartup` — on every
/// change, so flipping the toggle flips the posture of the running process without a
/// relaunch (see `apply(_:)`).
///
/// `LSUIElement = true` in `Info.plist` is the bulletproof half of mode B: the process
/// can never leak a Dock tile by accident. Mode A overrides it at runtime with
/// `NSApp.setActivationPolicy(.regular)` (`docs/ARCHITECTURE.md` §1).
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

    /// The current posture. Starts as the launch-resolved mode and is flipped in place
    /// when the Run at Startup toggle completes.
    private(set) var mode: AppMode

    /// Subscriptions that flip the mode when `runAtStartup` changes.
    private var cancellables: Set<AnyCancellable> = []

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

    // MARK: - Init

    /// - Parameter mode: forces a mode, overriding the argument scan and the plist read.
    ///   Exists so the mode is testable without mutating `CommandLine` or the user's
    ///   login items.
    init(mode: AppMode? = nil) {
        self.mode = mode ?? AppMode.resolve(
            menuBarOnlyArgument: AppDelegate.requestedMenuBarOnly(),
            launchAgentInstalled: StartupManager().isInstalled())
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
        Trace.log("launch didFinishLaunching mode=\(mode.rawValue)")

        // Posture first, *before* any UI exists, so there is no window of time in which
        // the wrong Dock icon can appear. Info.plist says `LSUIElement = true`; mode A
        // overrides it at runtime, mode B confirms it.
        NSApp.setActivationPolicy(mode == .menuBarGadget ? .accessory : .regular)

        // The menu-bar controller is built on the MAIN thread, synchronously, here —
        // never later and never off-main. AppKit status items created off the main
        // thread do not reliably appear, and creating one lazily on first click is
        // exactly how the macOS 26 "process alive, nothing on screen" report happens.
        // In mode A the controller deliberately creates no status item at all.
        assert(Thread.isMainThread, "the menu-bar controller must be built on the main thread")
        let controller = MenuBarController(coordinator: coordinator,
                                           gadgetMode: mode == .menuBarGadget)
        menuBarController = controller
        isReady = true

        // Unprivileged state read: opening the app must never cost a password prompt.
        coordinator.loadState()

        let autoBoot = coordinator.availability(for: .autoBoot).isEnabled ? "available" : "locked"
        let rosetta = coordinator.availability(for: .rosetta2).isEnabled ? "available" : "locked"
        Trace.log("launch started arch=\(coordinator.architecture.displayName) "
            + "macOS=\(Trace.osVersionText()) AutoBoot=\(autoBoot) Rosetta2=\(rosetta)")

        // Flipping Run at Startup changes the running process's posture, not just the
        // next launch: ON installs the menu-bar icon, OFF removes it and restores the
        // Dock icon. The published value is authoritative — it is re-read from disk
        // after every operation — so observation can never drift from the toggle.
        coordinator.$runAtStartup
            .dropFirst() // the current value is already reflected by `mode`
            .receive(on: RunLoop.main)
            .sink { [weak self] isInstalled in
                guard let self = self else { return }
                self.apply(isInstalled ? .menuBarGadget : .normal)
            }
            .store(in: &cancellables)

        // A cold start caused by Launch Services delivers the URL *after* this method
        // returns, so `application(_:open:)` handles it.
        //
        // Only now that the presenter exists is it safe to run anything that was queued.
        drainPendingURLs()

        // Mode A is an ordinary windowed app: the panel opens at launch. Mode B is the
        // background gadget — no window, ever, until the user asks for one.
        if mode == .normal {
            Trace.log("launch showing main window (normal mode)")
            controller.showMainWindow()
        } else {
            Trace.log("launch hidden (menu-bar gadget mode)")
        }
    }

    /// Applies a posture change to the running process.
    ///
    /// Called with the post-operation value of `runAtStartup`, so it is idempotent and
    /// never guesses:
    ///
    /// - `.menuBarGadget`: drop the Dock icon, install the menu-bar icon. Any open panel
    ///   is left on screen — the user is looking at it when they flip the switch — but
    ///   the next launch is hidden.
    /// - `.normal`: restore the Dock icon, remove the menu-bar icon, and bring the panel
    ///   forward. This is the "kill the gadget, become a normal app" half of the toggle,
    ///   and it is why the removal happens *inside* this process rather than via
    ///   `launchctl` (which would terminate the app that is asking).
    private func apply(_ newMode: AppMode) {
        guard newMode != mode else { return }
        Trace.log("mode transition \(mode.rawValue) → \(newMode.rawValue)")
        mode = newMode

        switch newMode {
        case .menuBarGadget:
            NSApp.setActivationPolicy(.accessory)
            menuBarController?.setGadgetMode(true)
        case .normal:
            NSApp.setActivationPolicy(.regular)
            menuBarController?.setGadgetMode(false)
            menuBarController?.showMainWindow()
        }
    }

    /// The Dock icon (or a Finder double-click) asks the running app for its window.
    ///
    /// Mode A has a Dock icon, so this is the normal way back to a closed panel; mode B
    /// has none, but Launch Services activation can still get here. Either way the user
    /// asked for the app, so the panel is shown.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        Trace.log("reopen requested (hasVisibleWindows=\(flag)) → showing panel")
        menuBarController?.showMainWindow()
        return false // handled here; no AppKit window shuffling
    }

    /// Closing the panel must never quit the process.
    ///
    /// In mode B the menu-bar icon *is* the app, and in mode A the Dock icon is the way
    /// back to a closed panel (`applicationShouldHandleReopen`). Quitting is always an
    /// explicit action: ⌘Q, or Quit in the status-item menu.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - URL scheme

    /// Hard ceiling on the cold-start URL queue.
    ///
    /// Launch Services can deliver a burst of URLs (a shortcut that fires three actions, or
    /// a login item replaying them), and the queue is drained only once the presenter
    /// exists. Ten is far more than any real burst — and a queue that cannot be bounded is a
    /// queue that can grow without limit in a process nobody is watching. The **oldest**
    /// entries are dropped, so the most recent intent is the one that survives.
    private static let maxPendingURLs = 10

    /// Appends to the cold-start queue, enforcing the ceiling.
    ///
    /// Plain array bookkeeping on purpose. The queue is drained exactly once, by
    /// `drainPendingURLs()`, after `applicationDidFinishLaunching` has built the presenter.
    /// There is no re-dispatch and no `DispatchQueue.main.async` hop anywhere on this path,
    /// which is what makes both failure modes impossible: a URL that can be lost, and a
    /// drain that can re-enter itself.
    private func enqueue(_ urls: [URL]) {
        Trace.log("url queued count=\(urls.count) pending=\(pendingURLs.count) (presenter not ready yet)")
        pendingURLs.append(contentsOf: urls)
        guard pendingURLs.count > AppDelegate.maxPendingURLs else { return }
        let overflow = pendingURLs.count - AppDelegate.maxPendingURLs
        pendingURLs.removeFirst(overflow)
        Trace.log("url queue ceiling=\(AppDelegate.maxPendingURLs) exceeded: dropped \(overflow) oldest")
    }

    /// Handles `rosettastone://…` delivered by Launch Services.
    ///
    /// This is the whole automation surface, and it belongs to mode B (Run at Startup
    /// ON): the gadget is always running, so Launch Services reaches a live instance and
    /// the action lands immediately. A cold start still works — the URL is queued by
    /// `handle(urls:)` until the presenter exists. In mode A URLs are refused; see the
    /// mode gate there.
    func application(_ application: NSApplication, open urls: [URL]) {
        Trace.log("url delivered count=\(urls.count) "
            + urls.map(\.absoluteString).joined(separator: ","))
        handle(urls: urls)
    }

    /// Routes URLs now, or queues them until the presenter is ready.
    ///
    /// The queue is what guarantees all seven Shortcuts actions work on a cold start: the
    /// URL can legally arrive before `applicationDidFinishLaunching` has built the
    /// presenter, and losing it would silently do nothing for the user.
    ///
    /// ## Mode gate
    ///
    /// URL actions are the **power-user (Mode B, Run at Startup ON)** surface. In mode A
    /// the app is an ordinary windowed app that is not running in the background, so URL
    /// actions are refused — with an explanation in the panel footer rather than a silent
    /// no-op — and only recognised actions are reported. A malformed URL stays silent in
    /// every mode.
    func handle(urls: [URL]) {
        guard !urls.isEmpty else { return }

        guard mode == .menuBarGadget else {
            let recognised = urls.filter { URLAction.kind(for: $0) != nil }
            guard !recognised.isEmpty else {
                Trace.log("url ignored in normal mode (unknown action)")
                return
            }
            Trace.log("url refused in normal mode count=\(recognised.count) "
                + "(URL actions require Run at Startup)")
            coordinator.report(URLActionRouter.normalModeRefusalMessage, style: .info)
            if isReady { menuBarController?.showMainWindow() }
            return
        }

        guard isReady, let presenter = menuBarController else {
            enqueue(urls)
            return
        }
        // `MenuBarController` is the presenter: it owns the window and raises the sheet.
        for url in urls {
            URLActionRouter.route(url, coordinator: coordinator, presenter: presenter)
        }
    }

    /// Executes everything queued during launch. Called exactly once, from
    /// `applicationDidFinishLaunching`, and only after the presenter exists.
    ///
    /// The guard is re-checked rather than assumed: `drainPendingURLs` must not be able to
    /// re-enter itself or run against a half-built presenter.
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
