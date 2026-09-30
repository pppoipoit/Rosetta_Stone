import AppKit
import SwiftUI
import Combine

/// Owns the menu-bar item and the main panel window.
///
/// ## Why AppKit and not `MenuBarExtra`
///
/// `MenuBarExtra` requires macOS 13. The deployment floor is macOS 10.15, so the status
/// item is an AppKit `NSStatusItem` managed explicitly (ADR-001). This is the only file
/// that has to know; everything else in the app is pure SwiftUI.
///
/// ## Window ownership
///
/// The panel is an `NSWindow` created and retained here rather than by SwiftUI, which
/// gives deterministic show/hide behaviour and lets the app own its only window:
/// - `NSWindow` + `NSHostingView(ContentView)`,
/// - `.titled, .closable, .fullSizeContentView` with a transparent titlebar so the dark
///   panel bleeds to the edges like the mock-up,
/// - the window is *not* released when closed, so reopening is instant and the
///   coordinator's `@Published` state survives.
///
/// The dropdown menu and its actions are in `MenuBarController+Menu.swift`.
final class MenuBarController: NSObject {

    // MARK: - Properties

    let coordinator: FeatureCoordinator

    /// The status-bar item. Retained for the process lifetime.
    private var statusItem: NSStatusItem?

    /// The panel window. Retained even while hidden.
    private var window: NSWindow?

    /// `true` when the LaunchAgent started us and the app must be a menu-bar gadget only.
    ///
    /// When set, no window is ever built: not the panel, not the first-run window, not
    /// the diagnostics sheet. Only the status item and its dropdown exist.
    let menuBarOnly: Bool

    /// The dropdown menu shown on right-click. Built lazily on first use.
    private var menu: NSMenu = NSMenu()

    /// Which image source the status item actually resolved to. Surfaced by Diagnostics.
    private(set) var statusImageSource = "none"

    /// Cancellations of the subscriptions tying menu enablement to feature state.
    private var cancellables: Set<AnyCancellable> = []

    // MARK: - Init

    init(coordinator: FeatureCoordinator, menuBarOnly: Bool = false) {
        self.coordinator = coordinator
        self.menuBarOnly = menuBarOnly
        super.init()
        // Built once and retained for the process lifetime: the dropdown is presented
        // manually, and `updateMenuEnabledState` keeps mutating it.
        menu = makeMenu()

        // Status item FIRST, and unconditionally. The window is optional; the status item
        // is not. `--menu-bar-only` is precisely the mode in which the item is the whole app.
        installStatusItem()

        if menuBarOnly {
            Trace.log("window not created: --menu-bar-only")
        } else {
            buildWindow()
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
    private func installStatusItem() {
        assert(Thread.isMainThread, "NSStatusItem must be created on the main thread")

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
        button.toolTip = "Rosetta Stone"
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        // Both click types are delivered to the action. `item.menu` is deliberately
        // NOT set: a status item with a `menu` attached shows that menu on *any*
        // click and never sends its action, which would make the panel unreachable.
        // The dropdown is therefore presented manually on right-click below.
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        statusItem = item

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
        if #available(macOS 11.0, *) {
            if let symbol = NSImage(systemSymbolName: "square.stack.3d.up.fill") {
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
        guard let item = statusItem else { return "missing (never created)" }
        guard let button = item.button else { return "created, no button" }
        let hasImage = button.image != nil
        let hasTitle = !button.title.isEmpty
        // Both false would mean a zero-width item: the exact invisible-UI failure.
        if !hasImage && !hasTitle { return "created, ZERO WIDTH (no image, no title)" }
        return "created · width \(Int(button.bounds.width))pt · "
            + "image: \(hasImage ? statusImageSource : "none") · "
            + "title: \(hasTitle ? "\"\(button.title)\"" : "none")"
    }

    /// Left-click toggles the panel; right-click pops up the dropdown.
    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else {
            toggleMainWindow()
            return
        }
        if event.type == .rightMouseUp {
            presentMenu(from: sender)
        } else {
            toggleMainWindow()
        }
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
        panel.contentView = NSHostingView(rootView: ContentView(coordinator: coordinator))
        panel.center()

        window = panel
    }

    /// Shows the panel and focuses it.
    ///
    /// A no-op in `--menu-bar-only` mode: the window does not exist, and the whole point
    /// of that mode is that no window ever does. Logged, because "I clicked the glyph and
    /// nothing happened" is exactly the kind of report that needs an explanation.
    func showMainWindow() {
        guard let panel = window else {
            Trace.log("showMainWindow ignored: no window (menuBarOnly=\(menuBarOnly))")
            return
        }
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // A freshly opened panel must show current truth, not the state from the last
        // time it was closed. The re-read is unprivileged, so it costs nothing.
        coordinator.loadState()
        Trace.log("panel shown")
    }

    /// Hides the panel without destroying it.
    func hideMainWindow() {
        window?.orderOut(nil)
    }

    /// Shows the panel if hidden, hides it if visible. Bound to a left-click.
    func toggleMainWindow() {
        if let panel = window, panel.isVisible {
            hideMainWindow()
        } else {
            showMainWindow()
        }
    }

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

    /// Builds the menu-bar dropdown: version, the quick actions, and Quit.
    ///
    /// Kept small on purpose — the features live in the panel. This menu exists so the app
    /// is reachable while the panel is closed, which matters because there is no Dock icon.
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

        menu.addItem(.separator())

        let open = NSMenuItem(title: "Open Rosetta Stone",
                              action: #selector(openPanel),
                              keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        let hiddenFiles = NSMenuItem(title: "Toggle Hidden Files",
                                     action: #selector(toggleHiddenFiles),
                                     keyEquivalent: "")
        hiddenFiles.target = self
        menu.addItem(hiddenFiles)

        let dns = NSMenuItem(title: "Flush DNS Cache",
                             action: #selector(flushDNS),
                             keyEquivalent: "")
        dns.target = self
        menu.addItem(dns)

        let spotlight = NSMenuItem(title: "Rebuild Spotlight Index",
                                   action: #selector(rebuildSpotlight),
                                   keyEquivalent: "")
        spotlight.target = self
        menu.addItem(spotlight)

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

    @objc private func toggleGatekeeper() {
        coordinator.toggleGatekeeper()
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

        updateMenuEnabledState()
    }

    private func updateMenuEnabledState() {
        let busy = coordinator.isBusy
        for item in menu.items {
            guard let action = item.action else { continue }
            switch action {
            case #selector(toggleGatekeeper), #selector(toggleHiddenFiles),
                 #selector(flushDNS), #selector(rebuildSpotlight):
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
