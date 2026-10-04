import AppKit
import SwiftUI
import Combine

/// Owns the menu-bar item and the main panel window, in both app modes.
///
/// ## Why AppKit and not `MenuBarExtra`
///
/// `MenuBarExtra` requires macOS 13. The deployment floor is macOS 10.15, so the status
/// item is an AppKit `NSStatusItem` managed explicitly (ADR-001). This is the only file
/// that has to know; everything else in the app is pure SwiftUI.
///
/// ## The two modes
///
/// - **Mode A (Run at Startup OFF, the default):** there is **no status item at all**.
///   The controller exists only to own the window, and `AppDelegate` keeps the process
///   `.regular` so the Dock icon is visible.
/// - **Mode B (Run at Startup ON):** the status item is the app, and it has **two faces**
///   (Phase 11):
///   - **Left-click → the mini panel** (`MiniAppView`): a small, self-contained window with
///     three switches (Gatekeeper, Hidden Files, Run at Startup), an OK / CANCEL bar and a
///     route to the full app. It uses the **same deferred queue** as the main panel, so
///     nothing runs until OK and a batch still costs one password prompt.
///   - **Right-click** (or Control-click) → the full menu: Open Main Window, Toggle Hidden
///     Files, Flush DNS, Rebuild Spotlight, Clear System Cache… (confirmed), Diagnostics…
///     (⌘D), Quit Rosetta Stone (⌘Q).
///
/// Before Phase 11 a left-click toggled Gatekeeper directly. That was a good idea for a
/// panel that had no other face, but it became the wrong one once the gadget grew a real
/// UI: a single click that raises a password prompt and changes a **security** setting is not
/// something to discover by accident, and there was nowhere in the gadget to see or reverse
/// what it had just done. The direct toggle survives as the mini panel's Gatekeeper row.
///
/// `setGadgetMode(_:)` installs or removes the status item live, which is what makes the
/// Run at Startup toggle a posture switch rather than a next-login-only setting.
///
/// ## Window ownership
///
/// This class owns **two** windows: the main panel and the mini panel.
/// - The main panel is an `NSWindow` created and retained here rather than by SwiftUI, which
///   gives deterministic show/hide behaviour and lets the app own its only full window:
///   `NSWindow` + `NSHostingView(ContentView)`, `.titled, .closable, .fullSizeContentView`
///   with a transparent titlebar so the dark panel bleeds to the edges like the mock-up, and
///   `isReleasedWhenClosed = false` so reopening is instant and the coordinator's
///   `@Published` state survives.
/// - The mini panel is an `NSPanel`, built lazily on the first left-click and retained
///   thereafter for the same reason. It is built **only in mode B** — it is meaningless
///   without a status item to click, and building it in mode A would be dead weight.
/// - Both are built in mode B: the full panel is still needed for "Open Main Window", for
///   `rosettastone://open-app`, and for the destructive-action sheet.
///
/// The dropdown menu and its actions live in the extension at the bottom of this file.
final class MenuBarController: NSObject {

    // MARK: - Properties

    let coordinator: FeatureCoordinator

    /// The status-bar item. `nil` in mode A; retained for the process lifetime in mode B.
    private var statusItem: NSStatusItem?

    /// The panel window. Built in both modes and retained even while hidden.
    private var window: NSWindow?

    /// The mini menu-bar panel. Built lazily on the first left-click and retained
    /// thereafter, so the second click is instant and the queue survives being closed.
    private var miniPanel: NSPanel?

    /// `true` while the process is in mode B — the menu-bar gadget.
    ///
    /// Flips live: `AppDelegate` calls `setGadgetMode(_:)` the moment the Run at Startup
    /// toggle completes, so this is never stale relative to the login item.
    private(set) var gadgetMode: Bool

    /// The dropdown menu shown on right-click. Built once, in `init`.
    private var menu: NSMenu = NSMenu()

    /// Which image source the status item actually resolved to. Surfaced by Diagnostics.
    private(set) var statusImageSource = "none"

    /// `true` while a Gatekeeper outcome still has to be toasted.
    ///
    /// Armed when the user *stages* Gatekeeper — in the mini panel or the main panel, through
    /// the deferred queue — then cleared by whichever outcome signal fires first: a failure /
    /// "still running" message, or the state re-read that follows a completed operation.
    ///
    /// Since Phase 11 the left-click no longer toggles Gatekeeper directly, so this is no
    /// longer armed by a status-item click. It is armed from the mini panel's OK instead,
    /// which is the point: the gadget now toasts the outcome of a **queued** change, so the
    /// user gets feedback without the panel having to stay on screen.
    private var gatekeeperToastArmed = false

    /// Cancellations of the subscriptions tying menu enablement to feature state.
    private var cancellables: Set<AnyCancellable> = []

    // MARK: - Init

    /// - Parameter gadgetMode: `true` for mode B (status item installed, no window at
    ///   launch), `false` for mode A (no status item, window shown by the delegate).
    init(coordinator: FeatureCoordinator, gadgetMode: Bool) {
        self.coordinator = coordinator
        self.gadgetMode = gadgetMode
        super.init()
        // Built once and retained for the process lifetime: the dropdown is presented
        // manually, and `updateMenuEnabledState` keeps mutating it.
        menu = makeMenu()

        // The macOS 15+ Gatekeeper follow-up is a UI concern, so the coordinator reaches
        // the UI through this hook instead of importing AppKit itself.
        coordinator.onGatekeeperNeedsConfirmation = { [weak self] in
            self?.presentGatekeeperSettingsConfirmation()
        }

        // The window is NOT optional in either mode: mode B needs it for "Open Main
        // Window" and the destructive-action sheet, mode A is nothing but the window.
        buildWindow()

        // Mode B: the status item is the app, so it is created synchronously here, on the
        // main thread. Mode A deliberately has none.
        if gadgetMode {
            installStatusItemIfNeeded()
        } else {
            Trace.log("status item skipped: mode A (Run at Startup off)")
        }
        observeState()
    }

    deinit {
        // The status item must be removed explicitly; NSStatusBar does not track it.
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
    }

    // MARK: - Status item

    /// Creates the `NSStatusItem` and attaches the dropdown menu.
    ///
    /// ## Why this is written defensively
    ///
    /// The macOS 26 report was: process alive, **no menu-bar item at all**. A status item
    /// with neither an image nor a title has **zero intrinsic width**, so it occupies no
    /// space in the menu bar and is indistinguishable from "never created". Every
    /// assumption that could previously produce that state is now guarded:
    ///
    /// 1. **Main thread.** Called synchronously from `applicationDidFinishLaunching`.
    /// 2. **`variableLength`, never `0`.** A length of 0 is a guaranteed invisible item.
    /// 3. **An SF Symbol** (`macOS 11+`, behind `#available`) — if the symbol is renamed
    ///    or removed in a future macOS, `systemSymbolName:` returns `nil`…
    /// 4. **…so fall back to the `StatusBarIcon` asset**, shipped in `Assets.xcassets`…
    /// 5. **…then to the code-drawn glyph**, which cannot fail because it is not a
    ///    resource lookup at all.
    /// 6. **…and regardless, set a `title`.** The title is always assigned, so a nil image
    ///    falls back to rendering the 🗿 text rather than nothing.
    /// 7. **…then measure it.** `verifyStatusItemIsVisible()` re-checks the width on the
    ///    next runloop turn and promotes the title if the item is still zero-width, so the
    ///    "invisible item" state is not merely unlikely but actively corrected.
    private func installStatusItemIfNeeded() {
        assert(Thread.isMainThread, "NSStatusItem must be created on the main thread")
        guard statusItem == nil else {
            Trace.log("status item already present; not creating a second one")
            return
        }

        // 2. variableLength, explicitly. Never 0.
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        guard let button = item.button else {
            // No button == no way to show anything. Recorded loudly, because at this point
            // the app really is invisible and the log is the only remaining evidence.
            Trace.log("statusItem created=0 visible=0 (NSStatusBar returned no button)")
            statusItem = item
            return
        }

        let resolved = resolveStatusImage()
        statusImageSource = resolved.source
        button.image = resolved.image
        button.image?.isTemplate = true

        // The title is set **unconditionally**, and `imagePosition` is chosen so that
        // something is guaranteed to occupy width:
        //   • image present → `.imageOnly` renders just the glyph (the normal look),
        //   • image absent  → `.imageLeading` renders the 🗿 title instead.
        //
        // `.imageLeading` with both set would draw the glyph *and* the emoji side by side,
        // which is why it is not simply applied always. The title is retained in the
        // image-present case too: it costs nothing, and `verifyStatusItemIsVisible()`
        // below can promote it to be rendered if the item still measures zero width.
        button.title = MenuBarController.fallbackTitle
        button.imagePosition = resolved.image != nil ? .imageOnly : .imageLeading
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        // Both click types are delivered to the action. `item.menu` is deliberately
        // NOT set: a status item with a `menu` attached shows that menu on *any*
        // click and never sends its action, which would make the panel unreachable.
        // The dropdown is therefore presented manually on right-click below.
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        statusItem = item
        updateStatusItemToolTip()

        // 7. The trace that makes this bug diagnosable from a bug report alone.
        //    Built by string interpolation rather than `NSLog` varargs: passing a Swift
        //    `String` for `%@` through `CVarArg` is a latent format-string crash, and a
        //    crash here would reproduce the very "silent, invisible app" bug this fixes.
        Trace.log("statusItem created=1 visible=\(resolved.image != nil ? 1 : 0) "
            + "source=\(resolved.source) mode=\(button.imagePosition == .imageOnly ? "imageOnly" : "imageLeading") "
            + "title=set")

        verifyStatusItemIsVisible()
    }

    /// Last-resort guarantee that the status item is not zero-width.
    ///
    /// The image and title are already in place, so in practice this never has to do
    /// anything. It exists because **that is the entire bug**: an item measuring 0 pt is
    /// on screen exactly like an item that was never created, and the difference was
    /// invisible to the user and to the process.
    ///
    /// Width is measured on the next runloop turn, because AppKit lays the status item out
    /// asynchronously — reading `bounds` synchronously would report a stale 0 and produce
    /// a false positive on every launch. If the item really is still zero-width, the title
    /// is promoted to rendered (`.imageLeading`) so the 🗿 carries the width, and the
    /// failure is logged loudly so it is diagnosable from a bug report alone.
    private func verifyStatusItemIsVisible() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let item = self.statusItem,
                  let button = item.button else { return }

            guard button.bounds.width <= 0 else {
                Trace.log("statusItem verified visible width=\(Int(button.bounds.width))pt")
                return
            }

            Trace.log("statusItem ZERO WIDTH detected — promoting title to rendered")
            button.imagePosition = .imageLeading
            button.image = nil
        }
    }

    /// Text shown when — and only when — no image could be resolved.
    ///
    /// A stone emoji, chosen because it renders identically on every macOS from 10.15
    /// through 27 without shipping a font-specific asset. Emoji presentation in a status
    /// item is honoured by AppKit from 10.10 onward.
    static let fallbackTitle = "🗿"

    /// Which icon source actually won, so the log says *why* the item looks like it does.
    private struct ResolvedImage {
        let image: NSImage?
        let source: String
    }

    /// Walks the fallback chain in order: SF Symbol → asset → code-drawn glyph.
    private func resolveStatusImage() -> ResolvedImage {
        // 3. SF Symbol. `NSImage(systemSymbolName:)` is macOS 11+, so it needs a guard
        //    against the 10.15 floor. It is a *preference*, never a requirement.
        //    `accessibilityDescription:` is passed explicitly: it has a default in some
        //    SDKs and is a required argument in others (Xcode 26 / macOS 26 SDK), and
        //    naming it compiles against both.
        if #available(macOS 11.0, *) {
            if let symbol = NSImage(systemSymbolName: "square.stack.3d.up.fill",
                                    accessibilityDescription: "Rosetta Stone") {
                symbol.isTemplate = true
                return ResolvedImage(image: symbol, source: "sf-symbol")
            }
            Trace.log("statusItem SF Symbol unavailable; falling back to asset")
        }

        // 4. The bundled asset. Present in `Assets.xcassets` as `StatusBarIcon`.
        if let asset = NSImage(named: "StatusBarIcon") {
            asset.isTemplate = true
            return ResolvedImage(image: asset, source: "asset")
        }

        // 5. Drawn in code. Cannot be nil — no resource lookup, no symbol table — so the
        //    chain always terminates with a real image.
        return ResolvedImage(image: MenuBarController.makeGlyphImage(), source: "drawn-glyph")
    }

    /// Live description of the status item, for the Diagnostics panel.
    ///
    /// Reports *observable* facts rather than intent: whether the button exists, whether
    /// it has an image, whether it has a title, and how wide it actually is. A non-zero
    /// width is the single clearest answer to "is the item actually on screen?".
    var statusItemState: String {
        guard let item = statusItem else {
            // `nil` is correct and expected in mode A. In mode B it is precisely the
            // "process alive, nothing on screen" bug, so it is labelled as one.
            return gadgetMode
                ? "MISSING — mode B is on but no item was created (bug)"
                : "not installed (mode A — Run at Startup off)"
        }
        guard let button = item.button else { return "created, no button" }
        let hasImage = button.image != nil
        let hasTitle = !button.title.isEmpty
        // Both false would mean a zero-width item: the exact invisible-UI failure.
        if !hasImage && !hasTitle { return "created, ZERO WIDTH (no image, no title)" }
        return "created · width \(Int(button.bounds.width))pt · "
            + "image: \(hasImage ? statusImageSource : "none") · "
            + "title: \(hasTitle ? "\"\(button.title)\"" : "none")"
    }

    /// What AppKit is actually drawing.
    ///
    /// `NSStatusItem.isVisible` is the closest thing AppKit offers to answering "is my
    /// glyph on screen?", and it is what the diagnostics report leads with. From macOS 26
    /// Tahoe the user can also hide a third-party status item in **System Settings → Menu
    /// Bar → Rosetta Stone → Allow in the Menu Bar**; there is no public API that reports
    /// that switch, so the report carries the path to check instead.
    var statusItemVisibility: String {
        guard let item = statusItem else { return gadgetMode ? "no status item (bug)" : "no status item (normal mode)" }
        return item.isVisible ? "yes — AppKit reports the item as visible" : "NO — AppKit reports it as hidden"
    }

    /// **Left-click opens the mini panel.** **Right-click** (or Control-click) pops up the
    /// full dropdown.
    ///
    /// This is the mode B contract after Phase 11: the gadget's primary face is a real
    /// panel with real switches, and the dropdown is the secondary one. See the type
    /// documentation for why the direct Gatekeeper toggle moved off the left-click.
    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let isSecondaryClick = event?.type == .rightMouseUp
            || (event?.type == .leftMouseUp
                && event?.modifierFlags.contains(.control) == true)
        if isSecondaryClick {
            presentMenu(from: sender)
        } else {
            toggleMiniPanel(near: sender)
        }
    }

    /// Shows the mini panel, or hides it if it is already up.
    ///
    /// Toggling rather than only showing is what makes the click idempotent: clicking the
    /// status item again should dismiss, the same as clicking any other panel's owner.
    private func toggleMiniPanel(near button: NSStatusBarButton) {
        assert(Thread.isMainThread, "status-item clicks arrive on the main thread")

        if miniPanel?.isVisible == true {
            miniPanel?.orderOut(nil)
            Trace.log("mini panel hidden")
            return
        }
        showMiniPanel(near: button)
    }

    /// Hides the mini panel if it is on screen.
    ///
    /// Used when the app is about to put something else in front — a modal alert, or the
    /// main panel — so two panels are never stacked.
    func dismissMiniPanel() {
        guard miniPanel?.isVisible == true else { return }
        miniPanel?.orderOut(nil)
        Trace.log("mini panel dismissed programmatically")
    }

    /// Presents the mini panel from the main menu bar (Window → Mini Panel, ⌘M).
    ///
    /// A no-op in mode A: there is no status item to anchor to, and the mini panel is a
    /// gadget surface. Silently doing nothing would look like a broken menu item, so the
    /// refusal is traced.
    func presentMiniPanelFromMenu() {
        guard let button = statusItem?.button else {
            Trace.log("presentMiniPanelFromMenu ignored: no status item (normal mode)")
            return
        }
        showMiniPanel(near: button)
    }

    /// Orders both windows out, leaving the process alive. This is ⌘W.
    ///
    /// Both, not just the main panel: leaving the mini panel up behind a "minimized to the
    /// menu bar" action would be self-contradictory. `orderOut(_:)` rather than `close()`
    /// because closing would tear down the key-window state that makes ⌘W reversible.
    func hideAllWindows() {
        assert(Thread.isMainThread, "window visibility must change on the main thread")
        miniPanel?.orderOut(nil)
        window?.orderOut(nil)
    }

    /// Arms the outcome toast for a Gatekeeper change the user is about to commit.
    ///
    /// Called by the mini panel's OK when the queue holds a Gatekeeper toggle. The gadget's
    /// whole feedback model is the toast — the panel may well be dismissed by the time the
    /// password prompt is answered, so without this the user would learn the outcome only by
    /// reopening the app.
    ///
    /// Maintained as an explicit arm flag rather than "toast everything": a toast per
    /// operation would be noise, and this is the one change whose result is both
    /// security-relevant and invisible in any window the user is looking at.
    func armGatekeeperToast() {
        assert(Thread.isMainThread, "toast arming must happen on the main thread")
        gatekeeperToastArmed = true
    }

    /// The gatekeeper toast wording, so the mini panel, the main panel and the System
    /// Settings follow-up cannot describe the same outcome three different ways.
    ///
    /// `nil` state means `spctl --status` could not be read, which is reported as unknown
    /// rather than guessed at — the same rule the status dot follows.
    static func gatekeeperOutcomeText(bypassed: Bool?) -> String {
        switch bypassed {
        case .some(true):  return "Gatekeeper: disabled"
        case .some(false): return "Gatekeeper: enabled"
        case .none:        return "Gatekeeper: state could not be read"
        }
    }
    /// Builds (once) and shows the mini panel, positioned under the status item.
    ///
    /// ## Why an `NSPanel` and not a popover
    ///
    /// `NSPopover` would be the idiomatic choice, but it is a *transient*: it closes the
    /// moment it loses key focus and AppKit will not let it own a window the user parks.
    /// A panel gives the mini app a real, durable surface — which is what "mini app mode"
    /// means here. The cost is that AppKit does *not* dismiss it automatically, so the
    /// `didResignKey` observer below does it by hand.
    ///
    /// ## Positioning
    ///
    /// Anchored to the status item's own window converted to **screen** coordinates and then
    /// clamped to the visible frame. The conversion is required, not decorative: the status
    /// item's window is not the screen, and the clamp is what stops a status item near the
    /// right edge from putting half the panel off-screen.
    private func showMiniPanel(near button: NSStatusBarButton) {
        assert(Thread.isMainThread, "the mini panel must be presented on the main thread")

        let panel = miniPanel ?? makeMiniPanel()
        miniPanel = panel

        let size = panel.frame.size
        var origin: NSPoint

        if let hostWindow = button.window {
            // Two conversions, not one: `button.bounds` is in the *button view's* space, so
            // it must first be lifted into the window's space (passing `nil` as the base
            // view means "the window") and only then into screen coordinates. Converting the
            // button's bounds directly would be correct only while the button exactly fills
            // the status-item window, which is an assumption, not a guarantee.
            let inWindow = button.convert(button.bounds, to: nil)
            let host = hostWindow.convertToScreen(inWindow)
            origin = NSPoint(x: host.midX - size.width / 2,
                             y: host.minY - size.height - 4)
        } else if let visible = NSScreen.main?.visibleFrame {
            // The status item's window is gone — rare, but it happens on some display
            // arrangements. Fall back to the top-right corner rather than the origin.
            origin = NSPoint(x: visible.maxX - size.width - 12,
                             y: visible.maxY - size.height - 12)
        } else {
            origin = NSPoint(x: 16, y: 16)
        }

        if let visible = button.window?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
            let margin: CGFloat = 8
            origin.x = min(max(origin.x, visible.minX + margin),
                           visible.maxX - size.width - margin)
            origin.y = min(origin.y, visible.maxY - size.height - margin)
        }

        panel.setFrameOrigin(origin)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Trace.log("mini panel shown")
    }

    /// Builds the mini panel. Called at most once; the result is retained.
    private func makeMiniPanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0,
                                width: MiniAppView.panelWidth,
                                height: MiniAppView.panelHeight),
            // `.fullSizeContentView` is set at construction rather than inserted afterwards:
            // AppKit derives a window's frame behaviour and shadow from the style mask it was
            // created with, and mutating the mask later leaves the two out of step.
            styleMask: [.titled, .closable, .utilityWindow, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        panel.title = "Rosetta Stone"
        // A title bar on a 300 pt panel is chrome the user does not need. The panel draws
        // its own header with its own close button, and `.fullSizeContentView` lets the dark
        // background reach the top edge so it reads as part of this app rather than as a
        // second app that popped up.
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        // Retained across closes: rebuilding the hosting view on every click would reset the
        // mini panel's pending queue and re-read the hardware profile.
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isExcludedFromWindowsMenu = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.becomesKeyOnlyIfNeeded = false
        panel.minSize = NSSize(width: MiniAppView.panelWidth,
                               height: MiniAppView.panelHeight)

        panel.contentView = NSHostingView(rootView: MiniAppView(
            coordinator: coordinator,
            onDismiss: { [weak self] in
                self?.miniPanel?.orderOut(nil)
            },
            onOpenMainApp: { [weak self] in
                guard let self = self else { return }
                self.showMainWindow()
            },
            onArmGatekeeperToast: { [weak self] in
                // A Gatekeeper change committed from here may complete after the panel has
                // been dismissed, so the outcome has to reach the toast.
                self?.armGatekeeperToast()
            }))

        // AppKit does not auto-dismiss a panel on focus loss the way it does a popover, and a
        // panel that lingers behind another window looks stuck. Closing on resign-key is what
        // makes it behave like the popover users expect.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main) { [weak self, weak panel] _ in
                guard let self = self, self.miniPanel === panel else { return }
                panel?.orderOut(nil)
                Trace.log("mini panel dismissed (lost key)")
            }

        Trace.log("mini panel built \(MiniAppView.panelWidth)x\(MiniAppView.panelHeight)")
        return panel
    }

    /// Pops the dropdown up under the status item, anchored to its button.
    ///
    /// `nil` positioning lets AppKit place it, which keeps it on screen for an item in
    /// the trailing region of the menu bar.
    private func presentMenu(from button: NSStatusBarButton) {
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height), in: button)
    }

    // MARK: - Panel window

    /// Builds the panel window and hosts `ContentView` inside it.
    private func buildWindow() {
        let panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: ContentView.panelWidth, height: ContentView.panelHeight),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        panel.title = "Rosetta Stone"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        // Keep the window alive when closed so state is preserved between openings.
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isExcludedFromWindowsMenu = true
        // The panel is dark by design (see `Theme`), independent of system appearance.
        panel.appearance = NSAppearance(named: .darkAqua)
        // The panel's Diagnostics link. Mode A has no menu-bar icon at all, so this is
        // the only route to the diagnostics report there.
        panel.contentView = NSHostingView(rootView: ContentView(
            coordinator: coordinator,
            onShowDiagnostics: { [weak self] in
                guard let self = self else { return }
                DiagnosticsPanel.present(from: self)
            }))
        panel.center()

        window = panel
    }

    /// Brings the full panel forward.
    ///
    /// Works in both modes: in mode B it is the "Open Main Window" menu item and the
    /// landing point for `rosettastone://open-app`; in mode A it is how the app comes
    /// back after the user closes the panel. It is never called automatically at launch
    /// in mode B.
    func showMainWindow() {
        // Never leave the mini panel on top of the full one: two Rosetta Stone panels at
        // once looks like a bug and makes the mini panel's OK ambiguous about which queue
        // it is committing.
        dismissMiniPanel()

        guard let panel = window else {
            Trace.log("showMainWindow ignored: no window")
            return
        }
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // A freshly opened panel must show current truth, not the state from the last
        // time it was closed. The re-read is unprivileged, so it costs nothing.
        coordinator.loadState()
        Trace.log("panel shown")
    }

    // MARK: - Live mode switching

    /// Installs or removes the status item, live.
    ///
    /// Called by `AppDelegate.apply(_:)` the moment the Run at Startup toggle completes.
    /// Removing the item **in-process** is the "kill the menu-bar icon" half of turning
    /// the toggle OFF; shelling out to `launchctl bootout` would have terminated this
    /// very process instead of letting it return to normal mode.
    func setGadgetMode(_ enabled: Bool) {
        assert(Thread.isMainThread, "status item changes must happen on the main thread")
        guard enabled != gadgetMode else { return }
        gadgetMode = enabled
        if enabled {
            Trace.log("gadget mode ON — installing status item")
            installStatusItemIfNeeded()
        } else {
            Trace.log("gadget mode OFF — removing status item")
            removeStatusItem()
        }
    }

    /// Tears the status item down. The process keeps running.
    private func removeStatusItem() {
        // The mini panel is meaningless without a status item to toggle it, and leaving it
        // on screen after leaving mode B would strand a panel the user cannot re-open.
        dismissMiniPanel()

        guard let item = statusItem else { return }
        NSStatusBar.system.removeStatusItem(item)
        statusItem = nil
        Trace.log("status item removed")
    }

    /// Keeps the tooltip truthful about what a click will do.
    ///
    /// The tooltip is the only thing that can tell the user what the glyph will do before
    /// they commit to it, and it now has to describe **two** different faces rather than one.
    private func updateStatusItemToolTip() {
        guard let button = statusItem?.button else { return }
        let state: String
        switch coordinator.gatekeeperBypassed {
        case .some(true):  state = "Gatekeeper is bypassed."
        case .some(false): state = "Gatekeeper is active."
        case .none:        state = "Gatekeeper state is unknown."
        }
        button.toolTip = "Rosetta Stone — \(state) "
            + "Left-click for the mini panel, right-click for the full menu."
    }

    /// The macOS 15+ second step of disabling Gatekeeper.
    ///
    /// `FeatureCoordinator` calls this the moment `spctl --master-disable` succeeds on
    /// macOS 15 / 26 / 27: the CLI alone no longer flips the user-visible switch, so
    /// System Settings is opened and the user is told exactly what to choose. The
    /// instruction copy is Thai by owner decision (`GatekeeperPolicy.confirmationMessage`).
    ///
    /// ## Why the one-second delay (Phase 11)
    ///
    /// Owner requirement. `spctl --master-disable` returns *before* the user has seen
    /// anything — no notification, no window change. Launching System Settings in that gap
    /// produces the worst possible sequence: a password sheet closes, the app vanishes, and
    /// a different, scarier app is suddenly in front with no explanation of the connection.
    /// One second is long enough for the outcome toast to be read and the windows to settle,
    /// and short enough that the follow-up does not feel like an unrelated action.
    ///
    /// The **toast** is raised immediately and is not delayed, so "Gatekeeper: disabled" is
    /// visible during the gap; only System Settings waits.
    func presentGatekeeperSettingsConfirmation() {
        assert(Thread.isMainThread, "the confirmation alert must be raised on the main thread")

        Trace.log("gatekeeper: macOS 15+ confirmation step — scheduling System Settings")

        // The outcome is the news; the follow-up is the paperwork.
        StatusItemToast.show(
            coordinator.gatekeeperBypassed == true
                ? "\(MenuBarController.gatekeeperOutcomeText(bypassed: true)) — one more step in System Settings."
                : MenuBarController.gatekeeperOutcomeText(bypassed: false),
            near: statusItem?.button)

        DispatchQueue.main.asyncAfter(deadline: .now() + MenuBarController.settingsFollowUpDelay) {
            Trace.log("gatekeeper: opening System Settings after the delay")
            if let url = URL(string: GatekeeperPolicy.settingsURL) {
                _ = NSWorkspace.shared.open(url)
            }

            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Gatekeeper — one more step"
            alert.informativeText = GatekeeperPolicy.confirmationMessage
            alert.addButton(withTitle: "OK")
            // A gadget may own no key window: activate first so the alert cannot open behind
            // whatever the user was using.
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    /// Seconds between a successful `spctl --master-disable` and System Settings opening.
    ///
    /// A named constant rather than a literal at the call site, so the delay is greppable
    /// and tunable from one place.
    static let settingsFollowUpDelay: TimeInterval = 1.0

    /// Brings the app forward without showing the panel — used before a modal alert so
    /// the dialog is clearly attributed to Rosetta Stone.
    func activateApp() {
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - URLActionHandling

/// The menu-bar controller is the presenter for URL-driven actions: it owns the only
/// window, so it is the right place to show it and to raise a confirmation sheet.
extension MenuBarController: URLActionHandling {

    /// Presentations required by `URLActionHandling`. `showMainWindow()` already exists
    /// on the class itself, so only the destructive-action gate is added here.
    ///
    /// Used for `rosettastone://clear-cache`: a URL caller still does not get to delete
    /// `/Library/Caches` without the user being told exactly what happens.
    func performDestructiveAction(_ title: String, message: String, action: @escaping () -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Clear Cache")
        alert.addButton(withTitle: "Cancel")

        // Bring the panel forward so the dialog is clearly attributed to this app.
        showMainWindow()
        activateApp()

        if alert.runModal() == .alertFirstButtonReturn {
            action()
        }
    }
}

extension MenuBarController {

// MARK: - Dropdown menu

    /// Builds the menu-bar dropdown: version line, the quick actions, and Quit.
    ///
    /// This is the **right-click** menu — the left click never opens it. Kept small on
    /// purpose: the features live in the panel. It exists so the app is reachable while
    /// the panel is closed, which matters because the gadget has no Dock icon.
    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let title = NSMenuItem(title: "Rosetta Stone \(MenuBarController.versionString)",
                               action: nil,
                               keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)

        let architecture = NSMenuItem(title: "Running on \(coordinator.architecture.displayName)",
                                     action: nil,
                                     keyEquivalent: "")
        architecture.isEnabled = false
        menu.addItem(architecture)

        // Documents the primary click, which never opens this menu.
        let hint = NSMenuItem(title: "Left-click opens the mini panel",
                              action: nil,
                              keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)

        menu.addItem(.separator())

        let open = NSMenuItem(title: "Open Main Window",
                              action: #selector(openPanel),
                              keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        // The mini panel is normally a left-click, but a keyboard user has no left-click.
        // Without this item the gadget would be unreachable without a mouse, which is
        // exactly the accessibility gap a menu-bar app must not have.
        let mini = NSMenuItem(title: "Mini Panel…",
                              action: #selector(openMiniPanel),
                              keyEquivalent: "m")
        mini.target = self
        menu.addItem(mini)

        let hiddenFiles = NSMenuItem(title: "Toggle Hidden Files",
                                     action: #selector(toggleHiddenFiles),
                                     keyEquivalent: "")
        hiddenFiles.target = self
        menu.addItem(hiddenFiles)

        let dns = NSMenuItem(title: "Flush DNS",
                             action: #selector(flushDNS),
                             keyEquivalent: "")
        dns.target = self
        menu.addItem(dns)

        let spotlight = NSMenuItem(title: "Rebuild Spotlight",
                                   action: #selector(rebuildSpotlight),
                                   keyEquivalent: "")
        spotlight.target = self
        menu.addItem(spotlight)

        // Feature 8: the menu keeps the same explicit confirmation as the panel — a
        // destructive command never runs from a menu click alone.
        let clearCache = NSMenuItem(title: "Clear System Cache…",
                                    action: #selector(confirmClearCache),
                                    keyEquivalent: "")
        clearCache.target = self
        menu.addItem(clearCache)

        menu.addItem(.separator())

        let diagnostics = NSMenuItem(title: "Diagnostics…",
                                     action: #selector(showDiagnostics),
                                     keyEquivalent: "d")
        diagnostics.target = self
        menu.addItem(diagnostics)

        let quit = NSMenuItem(title: "Quit Rosetta Stone",
                              action: #selector(quit),
                              keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    /// Opens the diagnostics report. Our lifeline for remote debugging — see
    /// `DiagnosticsPanel`.
    @objc private func showDiagnostics() {
        DiagnosticsPanel.present(from: self)
    }

    @objc private func openPanel() {
        showMainWindow()
    }

    /// Opens the mini panel from the dropdown (⌘M).
    ///
    /// Anchored to the status item when there is one, so the menu route and the left-click
    /// route land in the same place — otherwise "Mini Panel…" would open a floating window
    /// at an arbitrary position and the two routes would feel like different features.
    @objc private func openMiniPanel() {
        guard let button = statusItem?.button else {
            // Mode A has no status item. The mini panel is a gadget surface, so there is
            // nothing to anchor to and nothing to show — say so rather than opening an
            // unplaceable window.
            Trace.log("openMiniPanel ignored: no status item (normal mode)")
            return
        }
        toggleMiniPanel(near: button)
    }

    @objc private func toggleHiddenFiles() {
        // Read-then-write happens inside the coordinator's locked operation, so the pair
        // is atomic with respect to every other operation.
        coordinator.toggleHiddenFiles()
    }

    @objc private func flushDNS() {
        coordinator.flushDNS()
    }

    @objc private func rebuildSpotlight() {
        coordinator.rebuildSpotlight()
    }

    /// Right-click menu → **Clear System Cache…**.
    ///
    /// A standalone alert rather than the panel sheet: the menu is the gadget's interface,
    /// and opening the main window just to ask for a confirmation would defeat the mode.
    /// The warning text is the same constant the panel and the URL scheme use.
    @objc private func confirmClearCache() {
        assert(Thread.isMainThread, "menu actions arrive on the main thread")
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Clear the system cache?"
        alert.informativeText = FeatureID.clearSystemCacheWarning
        alert.addButton(withTitle: "Clear Cache")
        alert.addButton(withTitle: "Cancel")
        // An `.accessory` process may own no key window; activate first so the alert is
        // attributed to Rosetta Stone instead of appearing behind whatever is in use.
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            coordinator.clearSystemCache()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - State observation

    /// Disables the menu's quick actions while a privileged operation is in flight, so a
    /// second `osascript` prompt can never be triggered from the menu while one is open.
    private func observeState() {
        coordinator.$busyFeature
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateMenuEnabledState()
            }
            .store(in: &cancellables)

        // The tooltip is the direct Gatekeeper toggle's only feedback surface — there is
        // no window and no dropdown around it — so it is kept in sync with reality.
        coordinator.$gatekeeperBypassed
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateStatusItemToolTip()
            }
            .store(in: &cancellables)

        // Outcome feedback for a Gatekeeper change, split by who has the last word:
        //
        //  • a failure or a "still running" refusal is final — toast it immediately;
        //  • a dismissed password prompt publishes `nil`, so stand down silently;
        //  • otherwise the state publisher fires after the operation's authoritative
        //    re-read, and *that* is the truth the toast reports.
        //
        // The optimistic success message that `toggleGatekeeper()` publishes up front is
        // deliberately ignored: at that point nothing has happened yet.
        coordinator.$statusMessage
            .receive(on: RunLoop.main)
            .sink { [weak self] message in
                guard let self = self, self.gatekeeperToastArmed else { return }
                guard let message = message else {
                    self.gatekeeperToastArmed = false
                    StatusItemToast.dismiss()
                    return
                }
                guard message.style != .success else { return }
                self.gatekeeperToastArmed = false
                StatusItemToast.show(message.text, near: self.statusItem?.button)
            }
            .store(in: &cancellables)

        coordinator.$gatekeeperBypassed
            .dropFirst() // the value at subscription is not an outcome
            .receive(on: RunLoop.main)
            .sink { [weak self] bypassed in
                guard let self = self, self.gatekeeperToastArmed else { return }
                self.gatekeeperToastArmed = false
                // One wording table (`gatekeeperOutcomeText`), so the toast, the status dot
                // and the System Settings follow-up cannot describe one outcome three ways.
                StatusItemToast.show(
                    MenuBarController.gatekeeperOutcomeText(bypassed: bypassed),
                    near: self.statusItem?.button)
            }
            .store(in: &cancellables)

        updateMenuEnabledState()
    }

    private func updateMenuEnabledState() {
        let busy = coordinator.isBusy
        for item in menu.items {
            guard let action = item.action else { continue }
            switch action {
            case #selector(toggleHiddenFiles), #selector(flushDNS),
                 #selector(rebuildSpotlight), #selector(confirmClearCache):
                // One operation at a time: while any privileged command is in flight
                // every mutating item is disabled, so a second `osascript` prompt can
                // never be raised from the menu while one is already on screen.
                item.isEnabled = !busy
            default:
                // Opening the panel and quitting stay available at all times.
                item.isEnabled = true
            }
        }
    }

    // MARK: - Static helpers

    /// Marketing version and build number, as stamped by CI.
    static var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "v\(short) (\(build))"
    }

    /// Draws the status-bar glyph in code: a rounded "stone" with a carved notch.
    ///
    /// Drawn rather than shipped as an asset so the status item is visible even in a
    /// build whose asset catalog has no AppIcon yet.
    private static func makeGlyphImage() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            let body = NSRect(x: 2.5, y: 3.5, width: 13, height: 11)
            let stone = NSBezierPath(roundedRect: body, xRadius: 3, yRadius: 3)
            stone.lineWidth = 1.4

            // Template images must be drawn in black; macOS recolours them.
            NSColor.black.setStroke()
            stone.stroke()

            // The carved notch that reads as a "glyph" at 18 pt.
            let notch = NSBezierPath()
            notch.move(to: NSPoint(x: 6.5, y: 12.0))
            notch.line(to: NSPoint(x: 11.5, y: 6.0))
            notch.lineWidth = 1.4
            notch.stroke()

            return true
        }
        image.isTemplate = true
        return image
    }
}
