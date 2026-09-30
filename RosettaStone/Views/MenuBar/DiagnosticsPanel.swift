import AppKit

/// The "Diagnostics…" panel — the remote-debugging lifeline.
///
/// ## Why this exists
///
/// The macOS 26 report was unanswerable without it: "alive in Activity Monitor, nothing
/// on screen". There was no way for a user to tell us whether the status item had been
/// created, whether it had zero width, which icon source won, or whether the LaunchAgent
/// was even installed. Asking for a log file gets a slow, usually-unhelpful answer.
///
/// This panel answers all of it in one screenshot. Every field is read live from the
/// running process — none of it is cached or reconstructed.
///
/// ## Fields
/// | Field | Why it matters |
/// |-------|----------------|
/// | CPU architecture | Explains a greyed-out Auto Boot / Rosetta row |
/// | macOS version | Explains an SF Symbol that resolved differently |
/// | Process ID | Ties the panel to the right process in Activity Monitor |
/// | Activation policy | `.accessory` == no Dock icon, which surprises first-time users |
/// | Launch posture | `--menu-bar-only` vs a normal launch explains a missing window |
/// | Status item | The zero-width / missing-item diagnosis, directly |
/// | Icon source | Which link of the fallback chain actually won |
/// | LaunchAgent | Installed yes/no — the "doesn't start at login" diagnosis |
/// | First run flag | Whether `hasLaunchedOnce` has been recorded yet |
///
/// Built with plain AppKit rather than SwiftUI so it needs no hosting view and cannot be
/// the thing that fails to appear. The rows are selectable so the output can be copied
/// into a bug report.
enum DiagnosticsPanel {

    /// One label/value pair.
    private struct Field {
        let label: String
        let value: String
    }

    /// Collects every field, in display order.
    private static func fields(from controller: MenuBarController) -> [Field] {
        let coordinator = controller.coordinator
        let startup = coordinator.startupManager
        let defaults = UserDefaults.standard

        return [
            Field(label: "Version", value: MenuBarController.versionString),
            Field(label: "Process ID", value: "\(ProcessInfo.processInfo.processIdentifier)"),
            Field(label: "macOS", value: Trace.osVersionText()),
            Field(label: "CPU architecture",
                  value: coordinator.architecture.displayName
                    + (coordinator.architecture.isRunningUnderTranslation ? " (translated)" : "")),
            Field(label: "Activation policy",
                  value: NSApp.activationPolicy() == .accessory ? "accessory (no Dock icon)" : "regular"),
            Field(label: "Launch posture",
                  value: controller.menuBarOnly
                    ? "menu-bar only (--menu-bar-only)"
                    : "normal (window allowed)"),
            Field(label: "Status item", value: controller.statusItemState),
            Field(label: "Icon source", value: controller.statusImageSource),
            Field(label: "LaunchAgent installed", value: startup.isInstalled() ? "Yes" : "No"),
            Field(label: "LaunchAgent path", value: startup.installedExecutablePath() ?? "—"),
            Field(label: "LaunchAgent menu-bar-only",
                  value: !startup.isInstalled() ? "—"
                    : (startup.installedPlistIsMenuBarOnly()
                        ? "Yes" : "No (stale — re-toggle Run at Startup)")),
            Field(label: "First run completed",
                  value: defaults.object(forKey: AppDelegate.hasLaunchedOnceKey) == nil
                    ? "No (never shown)" : "Yes"),
            Field(label: "Bundle path", value: Bundle.main.bundlePath)
        ]
    }

    /// Renders the panel as a selectable plain-text report.
    static func report(from controller: MenuBarController) -> String {
        fields(from: controller).map { "\($0.label): \($0.value)" }
            .joined(separator: "\n")
    }

    /// Shows the panel modally, with a Copy button.
    ///
    /// In `--menu-bar-only` mode there is no window to attach a sheet to, so this uses a
    /// standalone `NSAlert`. That is still a window — but the mode's promise is about the
    /// *startup* posture ("no window at launch"), and the user has explicitly asked for
    /// diagnostics here, so showing one is correct.
    ///
    /// Main-thread only, asserted rather than annotated: the project targets Swift 5.0 /
    /// macOS 10.15, where `@MainActor` (Swift 5.5 concurrency) is not available.
    static func present(from controller: MenuBarController) {
        assert(Thread.isMainThread, "diagnostics must be presented on the main thread")

        let text = report(from: controller)

        // Logged as well as displayed: the log survives a screenshot being lost.
        Trace.log("diagnostics\n\(text)")

        let alert = NSAlert()
        alert.messageText = "Rosetta Stone — Diagnostics"
        alert.informativeText = "Copy this into a bug report if something is not behaving."
        alert.addButton(withTitle: "Copy Report")
        alert.addButton(withTitle: "Close")

        // A selectable text view: screenshots lose text, pasted text does not.
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 560, height: 300))
        textView.isEditable = false
        textView.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        textView.string = text
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 8, height: 8)

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 560, height: 300))
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        alert.accessoryView = scrollView
        // Menu-bar-only is an `.accessory` app with no Dock tile: it must be activated to
        // own a modal window, or the alert can open behind whatever the user was using.
        NSApp.activate(ignoringOtherApps: true)

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
