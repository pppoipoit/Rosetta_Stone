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

    // MARK: - Batch diagnostics channel (Phase 11.2)

    /// Grep marker for the batch-diagnostics channel. Filter on this in Console.app.
    static let batchPrefix = "[RS-BATCH]"

    /// Logging-only channel for the Apply (deferred batch) path.
    ///
    /// ## Why a second channel
    ///
    /// These lines exist to answer one question — "the owner pressed OK, entered a password,
    /// and nothing happened" — and they are only useful while that is being diagnosed. Keeping
    /// them behind their own prefix means someone filtering on `[RosettaStone]` still gets the
    /// lifecycle trace, and someone reproducing the bug filters on `[RS-BATCH]` and gets the
    /// whole batch path and nothing else.
    ///
    /// **No behaviour change.** Every call site of this function is a statement in its own
    /// right; nothing reads a value back from it.
    static func batch(_ message: String) {
        NSLog("%@[RosettaStone] %@", batchPrefix, message)
    }

    /// Renders a string with its control characters made visible.
    ///
    /// This exists because the symptom being diagnosed is partly invisible: `NSLog` and
    /// Console.app both mangle a bare CR/LF, and a stray `\r` **overwrites the line it was
    /// printed on**. A marker line that actually contained `\r` would therefore be
    /// unreproducible from the log — the exact opposite of what this channel is for.
    ///
    /// `\r` → `<CR>`, `\n` → `<LF>`, `\t` → `<TAB>`, and any other ASCII control byte becomes
    /// `<U+XXXX>`. Printable characters pass through untouched, so UTF-8 output (including the
    /// Thai copy) stays readable.
    static func escaped(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(value.count)
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\r": out += "<CR>"
            case "\n": out += "<LF>"
            case "\t": out += "<TAB>"
            default:
                // ASCII C0 controls and DEL, tested on the scalar value rather than through
                // `Unicode.Scalar.Properties` so this cannot drift with Foundation's enums.
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    out += "<U+" + String(format: "%04X", scalar.value) + ">"
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
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
