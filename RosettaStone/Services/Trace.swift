import Foundation

/// Lifecycle tracing for every startup and URL step.
///
/// ## Why plain `NSLog`
///
/// `os_log`/`Logger` is macOS 11+, and the deployment floor here is 10.15
/// (`project.yml`). `NSLog` has existed since 10.0, writes to the same unified log
/// that `Console.app` reads, and needs no availability guard. The `[RosettaStone]`
/// prefix is what users are told to filter on — see the Diagnostics section of
/// `docs/USER-GUIDE.md`.
///
/// ## Why this exists
///
/// The macOS 26 report was "the process is alive in Activity Monitor but there is no
/// window and no menu-bar item". That is a *silent* failure: nothing on screen, and no
/// error anywhere. Without these traces there is no way to distinguish "never started"
/// from "started but the status item was zero-width". Every lifecycle step now logs, so
/// the first question in any bug report — "did it get this far?" — is answerable from
/// the log alone.
enum Trace {

    /// Every trace line. Deliberately one format string shape so the output is greppable.
    static func log(_ message: String) {
        NSLog("[RosettaStone] %@", message)
    }

    /// Traces the arguments the process was actually launched with.
    ///
    /// Worth logging explicitly: the LaunchAgent now passes `--menu-bar-only`, and if a
    /// stale plist is in play this is the only way to see which mode actually booted.
    static func logLaunchContext(arguments: [String] = CommandLine.arguments) {
        log("launch pid=\(ProcessInfo.processInfo.processIdentifier) "
            + "args=\(arguments.joined(separator: " "))")
    }

    /// Formats an OS version as "26.0" / "15.4.1", matching what the panel header shows.
    static func osVersionText() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return v.patchVersion == 0
            ? "\(v.majorVersion).\(v.minorVersion)"
            : "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
}
