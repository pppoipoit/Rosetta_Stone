import Foundation

/// The single choke point for privilege escalation and the single place that spawns
/// processes — `docs/ARCHITECTURE.md` §6 layering rules 2 & 3.
///
/// ```
/// app → /usr/bin/osascript -e 'do shell script "…" with administrator privileges'
///         → Authorization Services → root /bin/sh -c "…"
/// ```
///
/// Elevation is used because it is the only mechanism available on macOS 10.15 without a
/// Developer ID certificate or a privileged helper tool (ADR-006).
enum SystemCommands {

    // MARK: - Configuration

    /// Output longer than this is truncated before it reaches the UI. `mdutil`,
    /// `softwareupdate` and `spctl` can all be surprisingly chatty.
    static let maxOutputBytes = 8_192

    /// Default timeout for a normal, fast command.
    static let defaultTimeout: TimeInterval = 30

    /// Timeout for commands that legitimately take minutes (Rosetta 2 install).
    static let longTimeout: TimeInterval = 900

    // MARK: - Gatekeeper procedure

    /// `true` when **disabling** Gatekeeper needs the user's confirmation in System
    /// Settings after `spctl --master-disable`.
    ///
    /// ## The version rule
    ///
    /// macOS 15 Sequoia — and macOS 26 Tahoe and macOS 27 Golden Gate after it — turned
    /// the master switch into a **two-step** procedure. The CLI command still flips the
    /// command-line assessment state, but the user-visible switch in System Settings
    /// (“Allow applications from: Anywhere”) has to be confirmed by the user:
    ///
    /// | macOS | Steps to bypass Gatekeeper |
    /// |-------|----------------------------|
    /// | 10.15 Catalina → 14 Sonoma | **1** — `spctl --master-disable`. Done. |
    /// | 15 Sequoia → 27 Golden Gate | **2** — the command, then the user picks **Anywhere** in System Settings |
    ///
    /// Re-enabling (`spctl --master-enable`, the OFF direction) is a single step on every
    /// version and is deliberately **not** covered by this rule: it never needs a human in
    /// System Settings.
    ///
    /// The OS-level follow-up — the deep link and the user-facing instruction — lives in
    /// `GatekeeperPolicy`, because that is copy and presentation, not command execution.
    /// The app cannot click “Anywhere” itself: System Settings is not scriptable for this
    /// switch, and automating a security downgrade would be indistinguishable from malware.
    ///
    /// - Parameter majorVersion: injectable so the rule is testable without the host OS.
    static func gatekeeperDisableRequiresSystemSettingsConfirmation(
        majorVersion: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    ) -> Bool {
        majorVersion >= 15
    }

    // MARK: - Unprivileged execution

    /// Runs an executable directly — no `sh -c`, so nothing is re-interpreted.
    ///
    /// The environment is built from scratch: a GUI agent launched at login has an
    /// unpredictable `PATH`, so `/usr/bin`, `/bin`, `/usr/sbin` and `/sbin` are set
    /// explicitly and nothing else is inherited.
    static func run(_ executable: String,
                    _ arguments: [String] = [],
                    timeout: TimeInterval = defaultTimeout) throws -> ProcessResult {

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": "en_US.UTF-8"
        ]

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        // Drain both pipes concurrently while the child runs. Reading them sequentially
        // deadlocks as soon as the child fills the 64 KB pipe buffer.
        var outData = Data()
        var errData = Data()
        let drained = DispatchGroup()
        let readQueue = DispatchQueue(label: "com.rosettastone.commandreader", attributes: .concurrent)
        for (handle, isStdout) in [(outPipe.fileHandleForReading, true), (errPipe.fileHandleForReading, false)] {
            drained.enter()
            readQueue.async {
                let data = handle.readDataToEndOfFile()
                if isStdout { outData = data } else { errData = data }
                drained.leave()
            }
        }

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }

        do {
            try process.run()
        } catch {
            throw CommandError.launchFailed(path: executable, underlying: error.localizedDescription)
        }

        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            // Give the child a moment to die so the readers can finish.
            _ = finished.wait(timeout: .now() + 3)
            drained.wait()
            throw CommandError.timedOut(command: executable, seconds: timeout)
        }

        drained.wait()
        return ProcessResult(standardOutput: decode(outData),
                             standardError: decode(errData),
                             exitCode: process.terminationStatus)
    }

    /// Runs a command through `/bin/sh -c`. Only for commands that genuinely need shell
    /// syntax (redirection, `||`, globbing) — never for user-supplied fragments.
    static func shell(_ script: String,
                      timeout: TimeInterval = defaultTimeout) throws -> ProcessResult {
        try run("/bin/sh", ["-c", script], timeout: timeout)
    }

    // MARK: - Elevated execution

    /// Runs `command` **as root** through `osascript`, presenting the standard macOS
    /// Authorization dialog. The app never sees or handles a password.
    ///
    /// - Returns: `.cancelled` when the user dismisses the dialog (AppleScript `-128`),
    ///   `.failure` with the child's stderr otherwise. Cancellation is deliberately not
    ///   an error: `docs/ARCHITECTURE.md` §8 requires a silent revert.
    @discardableResult
    static func runAsAdmin(_ command: String,
                           timeout: TimeInterval = defaultTimeout) -> CommandOutcome {
        let osascript = "/usr/bin/osascript"
        let script = "do shell script \"\(appleScriptQuoted(command))\" with administrator privileges"

        let result: ProcessResult
        do {
            result = try run(osascript, ["-e", script], timeout: timeout)
        } catch {
            return .failure(message: shortDescription(of: error), exitCode: -1)
        }

        if result.isSuccess {
            return .success(output: result.standardOutput)
        }
        // osascript reports a dismissed dialog as "execution error: User canceled. (-128)".
        if result.standardError.contains("-128") || result.standardError.lowercased().contains("user canceled") {
            return .cancelled
        }
        return .failure(message: result.diagnosticText, exitCode: result.exitCode)
    }

    /// Unprivileged convenience wrapper: runs a shell command and maps the outcome.
    @discardableResult
    static func runShell(_ script: String,
                         timeout: TimeInterval = defaultTimeout) -> CommandOutcome {
        do {
            let result = try shell(script, timeout: timeout)
            if result.isSuccess { return .success(output: result.standardOutput) }
            return .failure(message: result.diagnosticText, exitCode: result.exitCode)
        } catch {
            return .failure(message: shortDescription(of: error), exitCode: -1)
        }
    }

    // MARK: - Batched execution (one Authorization dialog for the whole queue)

    /// Prefix for a successful command's marker line in a batch's stdout.
    static let batchOKPrefix = "RS_OK:"

    /// Prefix for a failed command's marker line.
    static let batchFailPrefix = "RS_FAIL:"

    /// The per-item outcome of one batch. Ordered, matching the submitted commands.
    struct BatchResult {
        let items: [BatchItemResult]

        var isEmpty: Bool { items.isEmpty }
        var allSucceeded: Bool { items.allSatisfy { $0.succeeded } }
    }

    /// Runs a whole queue, raising **at most one** macOS password dialog.
    ///
    /// This is the whole point of the deferred queue (ADR-009). Before batching, five
    /// privileged changes meant five `osascript` invocations and five password sheets — the
    /// user retyped the same password once per row, and each prompt stole focus separately.
    ///
    /// ## How it works
    ///
    /// 1. Commands are split by `requiresAdmin`.
    /// 2. The privileged ones are concatenated into **one** shell script, where each command
    ///    is wrapped so that it always prints exactly one marker line:
    ///    `if ( cmd ) >/dev/null 2>&1 ; then echo 'RS_OK:x' ; else echo 'RS_FAIL:x' ; fi`.
    ///    That script runs inside a single `do shell script … with administrator privileges`.
    /// 3. stdout is parsed for those markers, giving a per-command success/failure.
    ///    Markers are **exact** matches, so one row can never be mistaken for another.
    /// 4. Unprivileged commands run separately, without any prompt.
    ///
    /// - Returns: `.cancelled` for **every** command when the user dismisses the Authorization
    ///   dialog — including the unprivileged ones, which then do not run. Dismissing the dialog
    ///   means "not now" to the whole set, and running half of it would be exactly the
    ///   half-applied state the queue exists to prevent.
    static func runBatched(_ commands: [FeatureCommand]) -> BatchResult {
        guard commands.isEmpty == false else { return BatchResult(items: []) }

        let privileged = commands.filter { $0.requiresAdmin }
        let unprivileged = commands.filter { $0.requiresAdmin == false }

        var items: [BatchItemResult] = []

        // --- One Authorization dialog for every privileged command -----------------------
        if privileged.isEmpty == false {
            let script = batchScript(for: privileged)
            // The batch lives or dies by its slowest member: a Rosetta 2 install alongside
            // three toggles must not be cut off at the 30 s default.
            let timeout = privileged.map { $0.timeout }.max() ?? defaultTimeout
            let outcome = runAsAdmin(script, timeout: timeout)

            switch outcome {
            case .cancelled:
                // The user dismissed the dialog, which is itself the answer. **Nothing in the
                // batch runs** — including the unprivileged half. Running the LaunchAgent write
                // here while Gatekeeper silently did not change would produce exactly the
                // half-applied state the queue exists to prevent: the user said "not now" to
                // the whole set, so every row reports cancelled and Apply can be pressed again.
                return BatchResult(items: commands.map {
                    BatchItemResult(feature: $0.feature, outcome: .cancelled)
                })
            case .failure(let message, _):
                // The elevated shell itself failed (bad AppleScript, launch failure,
                // timeout). No marker can be trusted, so no privileged row is reported as
                // succeeded — but the unprivileged ones are independent and still run.
                items += privileged.map {
                    BatchItemResult(feature: $0.feature,
                                    outcome: .failure(message: message, exitCode: -1))
                }
            case .success(let output):
                items += parseBatchMarkers(output, commands: privileged)
            }
        }

        // --- Unprivileged commands, no prompt ---------------------------------------------
        for command in unprivileged {
            switch command.work {
            case .inline(let work):
                items.append(BatchItemResult(feature: command.feature, outcome: work()))
            case .shell(let script):
                items.append(BatchItemResult(feature: command.feature,
                                             outcome: runShell(script, timeout: command.timeout)))
            }
        }

        return BatchResult(items: items)
    }

    /// Builds the single elevated shell script for a batch.
    ///
    /// Each command is wrapped so it emits exactly one marker and **cannot** pollute stdout
    /// with its own output — `spctl`, `nvram` and `rm` all print things, and a stray line
    /// would corrupt marker parsing.
    ///
    /// The `if/then/else` form is used rather than `cmd && echo OK || echo FAIL`: in an `&&`
    /// chain, a command whose *last* statement fails can emit both markers, which would make
    /// one row look half-applied.
    static func batchScript(for commands: [FeatureCommand]) -> String {
        var lines: [String] = []
        for command in commands {
            guard let script = command.shell else { continue }
            lines.append(
                "if ( \(script) ) >/dev/null 2>&1 ; "
                    + "then echo '\(batchOKPrefix)\(command.marker)' ; "
                    + "else echo '\(batchFailPrefix)\(command.marker)' ; fi"
            )
        }
        // `;` separators keep every line independent: one command's failure must not abort
        // the rest of the batch, which is what a `set -e` script would do.
        return lines.joined(separator: " ; ")
    }

    /// Maps a batch script's stdout back onto per-command outcomes.
    ///
    /// A command with **no** marker is treated as a failure, never a success: silence is not
    /// evidence. That is the same "never trust the exit code" rule the single-command paths
    /// follow, applied to a multi-command exit code that is always 0.
    static func parseBatchMarkers(_ output: String,
                                  commands: [FeatureCommand]) -> [BatchItemResult] {
        // `components(separatedBy: .newlines)` rather than a hand-rolled `split` closure.
        // A marker is compared with `==`, so a stray `\r` from a CRLF line ending would turn a
        // real success into a silent "no result" failure. `.newlines` covers `\n`, `\r\n` and
        // `\r` in one call, and trimming with `.whitespacesAndNewlines` removes any padding the
        // shell adds around an `echo`.
        let lines = output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }

        var seen: [FeatureID: CommandOutcome] = [:]
        for line in lines {
            for command in commands {
                if line == "\(batchOKPrefix)\(command.marker)" {
                    seen[command.feature] = .success(output: "")
                } else if line.hasPrefix("\(batchFailPrefix)\(command.marker)") {
                    seen[command.feature] = .failure(
                        message: "\(command.feature.title) could not be applied.",
                        exitCode: -1)
                }
            }
        }

        return commands.map { command in
            BatchItemResult(feature: command.feature,
                            outcome: seen[command.feature]
                                ?? .failure(
                                    message: "\(command.feature.title) did not report a result.",
                                    exitCode: -1))
        }
    }

    /// AppleScript that makes Finder re-read its preferences **without restarting**.
    ///
    /// ## Why not `killall Finder`
    ///
    /// The original implementation was `defaults write … ; killall Finder`. That works, and
    /// it is why this row was documented as "restarts Finder" — but it kills the process
    /// every Finder window lives in, so the Dock and desktop blink out and back, every
    /// window's scroll position and open-tab state is lost, and anything mid-download in a
    /// window restarts. That is a large, visible side effect for a boolean preference.
    ///
    /// ## Why AppleScript instead of a Finder restart
    ///
    /// `NSAppleScript` is the only supported way to make a *running* Finder act on a changed
    /// preference. `update every window` tells each window to re-read the setting, so the
    /// change is visible immediately and nothing is destroyed.
    ///
    /// Two details that are load-bearing:
    ///
    /// 1. **`update every window` is required.** Setting `AppleShowAllFiles` alone changes
    ///    the preference but leaves open windows showing stale content; the update is what
    ///    makes it visibly take effect. Skipping it produces a toggle that "did nothing".
    /// 2. **Automation permission.** Controlling Finder is a TCC-protected operation, so on
    ///    a first run macOS may prompt for permission to "control Finder". The prompt is
    ///    honest about what is being asked and declining it does not break the toggle — the
    ///    preference is still written, and a Finder launched later will honour it. A refusal
    ///    is therefore reported as success-with-a-note rather than as a failure, because the
    ///    setting really was applied.
    ///
    /// Returned as an optional error rather than thrown: the caller needs to distinguish
    /// "AppleScript was refused" from "the process could not start", and both are outcomes
    /// worth logging rather than crashing on.
    private static func refreshFinderWindows() -> String? {
        let source = """
        tell application "Finder"
            update every window
        end tell
        """
        guard let script = NSAppleScript(source: source) else {
            return "Finder's AppleScript could not be compiled."
        }
        var errorInfo: NSDictionary?
        // `executeAndReturnError` rather than `executeAndReturnResult`: we care whether the
        // tell block succeeded, not what it returned.
        _ = script.executeAndReturnError(&errorInfo)
        if let errorInfo = errorInfo, let message = errorInfo[NSAppleScript.errorMessage] as? String {
            return message
        }
        return nil
    }

    /// Shows or hides dotfiles in Finder, **without restarting Finder**.
    ///
    /// This is feature 3's single write path, called identically from the panel's deferred
    /// queue, the menu-bar item and the URL scheme — there is exactly one implementation, so
    /// the three routes cannot drift (the same reason `FeatureCoordinator.command(for:pending:)`
    /// is the one command table).
    ///
    /// The preference write is still `defaults`, deliberately: it is unprivileged, it is the
    /// same key `SystemStateReader.areHiddenFilesShown()` reads back, and it keeps the
    /// durable truth independent of Finder being scriptable. The AppleScript is layered on
    /// afterwards purely to make running windows notice.
    ///
    /// - Parameter shown: `true` reveals dotfiles, matching the row's ON == shown semantics.
    /// - Returns: success when the preference was written, even if Finder could not be
    ///   refreshed — see point 2 above. A failure is returned only when the *write* failed.
    static func setHiddenFilesShown(_ shown: Bool) -> CommandOutcome {
        let write = runShell("\(finderDefaultsTool) write com.apple.finder AppleShowAllFiles "
                             + (shown ? "YES" : "NO"))
        guard write.isSuccess else { return write }

        if let problem = refreshFinderWindows() {
            // The preference is written and will apply to the next Finder window, so this is
            // a success with a caveat rather than a failure. Logged so Diagnostics can show it.
            Trace.log("hidden files: preference written, Finder refresh declined (\(problem))")
            return .success(output: "Finder windows were not refreshed (\(problem)).")
        }
        return .success(output: "")
    }

    /// Path to `defaults`, the one place the Hidden Files write path names it.
    ///
    /// The immediate routes and the deferred-queue route both build their command through
    /// `FeatureCoordinator.command(for:pending:)`, so this constant exists to keep a second
    /// spelling of the path from creeping into either of them.
    private static let finderDefaultsTool = "/usr/bin/defaults"

    // MARK: - Quoting

    /// Wraps `value` in single quotes for `/bin/sh`, escaping embedded quotes as `'\''`.
    ///
    /// Required for every value interpolated into an elevated command — the command is
    /// interpreted by `sh`, so an unescaped space or quote would silently split it.
    static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    /// Escapes a string for embedding in an AppleScript double-quoted literal.
    /// Backslashes first, then quotes, so escaping is not applied twice.
    static func appleScriptQuoted(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: - Helpers

    private static func decode(_ data: Data) -> String {
        let trimmed = data.count > maxOutputBytes ? data.prefix(maxOutputBytes) : data
        return String(data: trimmed, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func shortDescription(of error: Error) -> String {
        // `LocalizedError.errorDescription` is `String?`, not `String`. Every
        // `CommandError` case returns a non-nil string, so the `??` is only a
        // formality — it keeps the return type non-optional without an `!`.
        if let commandError = error as? CommandError {
            return commandError.errorDescription ?? "The command could not be completed."
        }
        return error.localizedDescription
    }
}

/// Failures raised while *launching* or *waiting for* a command, as opposed to a
/// non-zero exit status (which arrives as a `ProcessResult`).
enum CommandError: LocalizedError {
    case launchFailed(path: String, underlying: String)
    case timedOut(command: String, seconds: TimeInterval)

    var errorDescription: String? {
        switch self {
        case .launchFailed(let path, let underlying):
            return "Could not run \(URL(fileURLWithPath: path).lastPathComponent): \(underlying)"
        case .timedOut(let command, let seconds):
            return "\(URL(fileURLWithPath: command).lastPathComponent) did not finish within \(Int(seconds)) seconds and was stopped."
        }
    }
}
