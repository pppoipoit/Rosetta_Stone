import AppKit

// Rosetta Stone supports macOS 10.15 → 27, and the two entry points available to a
// Swift app differ across that range:
//
//   • macOS 11+  — the SwiftUI `App` lifecycle (`RosettaStoneApp`), which provides
//                  `@NSApplicationDelegateAdaptor` and `onOpenURL`.
//   • macOS 10.15 — `SwiftUI.App` does not exist yet (Big Sur introduced it), so the
//                  AppKit `NSApplication` + `NSApplicationDelegate` pair is booted
//                  directly. This is exactly what `@main` expands to under the hood.
//
// Both branches construct the same `AppDelegate`, so all behaviour — the NSStatusItem,
// the panel, the URL-scheme handler, the CPU gating — lives in one implementation and
// cannot drift between OS versions.
//
// `MenuBarExtra` is deliberately **not** used anywhere: it requires macOS 13 and would
// force the deployment floor up. `NSStatusItem` has existed since 10.10 and behaves
// identically from 10.15 through 27 (ADR-001).

/// Retains the delegate for the 10.15 path.
///
/// `NSApplication.delegate` is a *weak* reference. Without a strong owner here the
/// delegate would be deallocated the instant this function returns, and the app would
/// run with no status item and no URL handling.
private var retainedDelegate: AppDelegate?

// Traced before anything else. The macOS 26 "process alive but invisible" report is only
// diagnosable if we know the arguments the process actually started with — in particular
// whether LaunchAgent passed `--menu-bar-only`.
Trace.logLaunchContext()

if #available(macOS 11.0, *) {
    RosettaStoneApp.main()
} else {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    retainedDelegate = delegate
    application.delegate = delegate
    Trace.log("bootstrapping via AppKit NSApplication (macOS 10.15 path)")
    // `Info.plist` carries no `NSMainNibFile`, so no nib is loaded — `run()` goes
    // straight to `applicationDidFinishLaunching(_:)`.
    application.run()
}
