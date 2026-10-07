import AppKit
import Combine

/// The application delegate — the app's real entry point on every supported OS version.
///
/// ## Two modes, one process
///
/// The **Run at Startup** toggle chooses the app's entire posture (`AppMode`):
///
/// | Mode | Toggle | Launch | Dock icon | Menu-bar icon |
/// |------|--------|--------|-----------|---------------|
/// | A — normal | OFF (default) | window shown | yes | no |
/// | B — gadget | ON | window hidden | no (`LSUIElement`) | always |
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
/// `MenuBarExtra` needs macOS 13, but the deployment floor is 10.15. So the status item
/// and the window live in AppKit; the panel's *contents* are SwiftUI, hosted in an
/// `NSHostingView`. `RosettaStoneApp` provides the SwiftUI `App` entry point on macOS 11+
/// and `main.swift` falls back to this delegate on 10.15 — both funnel into the same
/// delegate, so there is only ever one code path for behaviour.
///
/// ## The main menu is built here, not in a nib
///
/// `Info.plist` carries no `NSMainNibFile`, so nothing loads a menu bar. The app would
/// therefore have **no** application menu at all — and with it no ⌘Q, no ⌘W, and no way to
/// reach Quit from the keyboard. `installMainMenu()` builds one in code, which is what makes
/// those shortcuts real rather than aspirational (Phase 11).
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

    // MARK: - Init

    /// Designated initializer. **This `override` is load-bearing — do not remove it.**
    ///
    /// SwiftUI's `@NSApplicationDelegateAdaptor(AppDelegate.self)` creates the delegate
    /// through the Objective-C `-init` selector, not through any Swift initializer we
    /// write. Declaring our own designated initializer suppresses the inherited
    /// `NSObject.init()`, so Swift synthesises an `@objc init()` stub that traps. The app
    /// then dies with `EXC_BAD_INSTRUCTION` / SIGILL inside `AppDelegate.init()` during
    /// `main` — before any window appears, and only at *runtime*, so CI stays green.
    /// Overriding `init()` is what makes that selector a real, working entry point.
    /// The smoke-test step in `.github/workflows/build-mac-dmg.yml` guards this.
    override init() {
        self.mode = AppMode.resolve(
            menuBarOnlyArgument: AppDelegate.requestedMenuBarOnly(),
            launchAgentInstalled: StartupManager().isInstalled())
        super.init()
    }

    /// Forces a mode, overriding the argument scan and the LaunchAgent read.
    /// Exists so the mode is testable without mutating `CommandLine` or the user's
    /// login items.
    convenience init(mode: AppMode) {
        self.init()
        self.mode = mode
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

        // The menu is installed **after** the presenter exists, because every item in it
        // targets the controller. Installing it earlier would leave items pointing at a
        // presenter that does not exist yet if the menu bar were reachable during launch.
        installMainMenu()

        // Unprivileged state read: opening the app must never cost a password prompt.
        // Launch is resync trigger #1 of the truth-first set (Phase 11.4); the others are
        // `applicationDidBecomeActive`, `windowDidBecomeKey`, Apply and CANCEL.
        coordinator.loadState("launch")

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

        // Truth-first resync (Phase 11.4): a state that changed while the panel was in the
        // background — System Settings, an MDM policy, a terminal command — must be
        // re-read the moment the user comes back. Two triggers, both free (unprivileged):
        // the app becoming active, and any of this app's own windows becoming key.
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(windowDidBecomeKey),
                                               name: NSWindow.didBecomeKeyNotification,
                                               object: nil)

        // Mode A is an ordinary windowed app: the panel opens at launch. Mode B is the
        // background gadget — no window, ever, until the user asks for one.
        if mode == .normal {
            Trace.log("launch showing main window (normal mode)")
            controller.showMainWindow()
        } else {
            Trace.log("launch hidden (menu-bar gadget mode)")
        }
    }

    /// Resync trigger #2 (Phase 11.4): the app itself became active — the user switched
    /// back from another application, or clicked one of the panel's windows while the app
    /// was in the background.
    ///
    /// `NSApplicationDelegate` delivers this through `NSApplication.didBecomeActiveNotification`,
    /// so no extra observer is registered for it. The read is unprivileged, so re-reading
    /// on every activation costs nothing but a few milliseconds of CPU.
    func applicationDidBecomeActive(_ notification: Notification) {
        Trace.batch("resync: applicationDidBecomeActive — reloading state")
        coordinator.loadState("app didBecomeActive")
    }

    /// Resync trigger #3 (Phase 11.4): one of this app's windows became key — the user
    /// clicked from the main panel to the mini panel, reopened the panel, or a sheet
    /// finished and focus returned.
    ///
    /// Registered as a window observer rather than an app-level one because an already
    /// active app does not re-post `didBecomeActive` when focus moves between its own
    /// windows; without this, the second window would keep whatever state it was built
    /// with. `isVisible` filters the (rare) key notifications from windows that are being
    /// ordered out.
    @objc private func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window.isVisible else { return }
        Trace.batch("resync: window didBecomeKey (\(type(of: window))) — reloading state")
        coordinator.loadState("window didBecomeKey")
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

    // MARK: - The main menu (Phase 11)

    /// Builds the application menu in code, so ⌘Q, ⌘W and ⌘M actually exist.
    ///
    /// ## Why in code rather than a nib
    ///
    /// `Info.plist` has no `NSMainNibFile` — deliberately, since the app owns its window
    /// explicitly rather than letting AppKit load one. The side effect is that AppKit never
    /// installs a default menu, and an app with no application menu has no ⌘Q: on macOS the
    /// Quit item lives in that menu, not in the status-item dropdown. A user who has learned
    /// that ⌘Q quits an app would reasonably conclude this one is stuck.
    ///
    /// Building it in code keeps the no-nib property intact and makes the shortcuts real
    /// without opening Interface Builder.
    ///
    /// ## What is deliberately absent
    ///
    /// No "New", "Open" or Services menu. This app has one window, one panel and no
    /// documents, so a row of empty items is noise. The two menus built are the two that
    /// hold something real.
    func installMainMenu() {
        let mainMenu = NSMenu()

        // --- Application menu: the only home of ⌘Q -------------------------------------
        // `submenu`, not a plain item: macOS requires the first item of the main menu to
        // carry a submenu, and this is the one the system treats as the app's own menu.
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "Rosetta Stone")

        let about = NSMenuItem(title: "About Rosetta Stone",
                               action: #selector(presentAbout),
                               keyEquivalent: "")
        about.target = self
        appMenu.addItem(about)
        appMenu.addItem(.separator())

        let hide = NSMenuItem(title: "Hide Rosetta Stone",
                              action: #selector(NSApplication.hide(_:)),
                              keyEquivalent: "h")
        appMenu.addItem(hide)

        // `terminate`, not a custom action: the system selector is what performs the
        // standard termination dance (saving state, asking delegates for consent).
        let quit = NSMenuItem(title: "Quit Rosetta Stone",
                              action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        appMenu.addItem(quit)

        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // --- Window menu: ⌘W hides rather than closes -----------------------------------
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")

        let mainWindow = NSMenuItem(title: "Main Panel",
                                    action: #selector(showMainWindow),
                                    keyEquivalent: "")
        mainWindow.target = self
        windowMenu.addItem(mainWindow)

        let mini = NSMenuItem(title: "Mini Panel",
                              action: #selector(showMiniPanel),
                              keyEquivalent: "m")
        mini.target = self
        windowMenu.addItem(mini)

        windowMenu.addItem(.separator())

        // ⌘W **hides** the panel rather than closing it — the owner-specified "minimize to
        // the menu bar" behaviour. It has to hide: `isReleasedWhenClosed = false` keeps the
        // `NSHostingView` alive across a close, but a closed window also drops out of the
        // Window menu and stops being key, and in mode B there is no Dock icon to click.
        // Ordering it out preserves every one of those properties.
        let close = NSMenuItem(title: "Close Panel",
                               action: #selector(hideMainWindow),
                               keyEquivalent: "w")
        windowMenu.addItem(close)

        let minimize = NSMenuItem(title: "Minimize",
                                  action: #selector(NSWindow.performMiniaturize(_:)),
                                  // Deliberately **no** shortcut. macOS convention gives
                                  // Minimize ⌘M, but ⌘M is the mini panel everywhere in this
                                  // app's documentation and in the dropdown menu, and a menu
                                  // that binds one chord to two different actions silently
                                  // picks a winner rather than reporting the clash.
                                  keyEquivalent: "")
        windowMenu.addItem(minimize)

        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
        // Assigning `windowsMenu` is what makes the system maintain the Window menu's own
        // "Bring All to Front" and miniaturise entries.
        NSApp.windowsMenu = windowMenu
        Trace.log("main menu installed (Quit=⌘Q Close=⌘W Mini=⌘M)")
    }
    /// Shows the main panel. Routed from the Window menu.
    @objc private func showMainWindow() {
        menuBarController?.showMainWindow()
    }

    /// Shows the mini panel. Routed from the Window menu.
    ///
    /// Goes through the controller rather than building anything here, so the menu route and
    /// the left-click route present the *same* panel anchored to the *same* status item.
    @objc private func showMiniPanel() {
        menuBarController?.presentMiniPanelFromMenu()
    }

    /// ⌘W — orders the panel out without closing or destroying it.
    ///
    /// The app stays alive and reachable in **both** modes: mode B through the status item,
    /// mode A through the Dock icon (`applicationShouldHandleReopen`). Closing would also
    /// work, but ordering out is reversible in every state and destroys nothing.
    @objc private func hideMainWindow() {
        assert(Thread.isMainThread, "menu actions arrive on the main thread")
        guard let controller = menuBarController else {
            Trace.log("hideMainWindow ignored: no presenter yet")
            return
        }
        controller.hideAllWindows()
        Trace.log("main panel hidden to the menu bar (⌘W)")
    }

    /// The About box. Minimal, but it is where the version lives once the panel is hidden.
    @objc private func presentAbout() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Rosetta Stone"
        alert.informativeText = "Version \(MenuBarController.versionString)\n"
            + "A Mac maintenance panel for Gatekeeper, hidden files, power and Rosetta.\n\n"
            + "Icons derived from a CC BY-SA 3.0 source; full attribution is in the project "
            + "repository."
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
