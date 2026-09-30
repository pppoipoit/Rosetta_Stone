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

    /// The dropdown menu shown on right-click. Built lazily on first use.
    private var menu: NSMenu = NSMenu()

    /// Template image used so the status item is never invisible. A stone-like glyph
    /// drawn in code — no bundled asset required. Template images are recoloured
    /// automatically for light and dark menu bars.
    private lazy var fallbackImage: NSImage = MenuBarController.makeGlyphImage()

    /// Cancellations of the subscriptions tying menu enablement to feature state.
    private var cancellables: Set<AnyCancellable> = []

    // MARK: - Init

    init(coordinator: FeatureCoordinator) {
        self.coordinator = coordinator
        super.init()
        // Built once and retained for the process lifetime: the dropdown is presented
        // manually, and `updateMenuEnabledState` keeps mutating it.
        menu = makeMenu()

        installStatusItem()
        buildWindow()
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
    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = fallbackImage
            button.image?.isTemplate = true
            button.imagePosition = .imageOnly
            button.toolTip = "Rosetta Stone"
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            // Both click types are delivered to the action. `item.menu` is deliberately
            // NOT set: a status item with a `menu` attached shows that menu on *any*
            // click and never sends its action, which would make the panel unreachable.
            // The dropdown is therefore presented manually on right-click below.
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
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
    func showMainWindow() {
        guard let panel = window else { return }
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // A freshly opened panel must show current truth, not the state from the last
        // time it was closed. The re-read is unprivileged, so it costs nothing.
        coordinator.loadState()
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

        let quit = NSMenuItem(title: "Quit Rosetta Stone",
                              action: #selector(quit),
                              keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        return menu
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
