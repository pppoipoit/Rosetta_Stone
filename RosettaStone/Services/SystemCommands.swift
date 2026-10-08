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

    /// The path to `spctl` for the **write** paths. (Reads keep their own constant in
    /// `SystemStateReader.Tool`, which is deliberately a different table — readers and
    /// writers never share a code path.)
    static let spctlTool = "/usr/sbin/spctl"

    /// The pending→command table for the Gatekeeper row — the **one** mapping, owner
    /// verified in Phase 11.4:
    ///
    /// | Row (toggle) | Meaning  | Command                        |
    /// |--------------|----------|--------------------------------|
    /// | **ON**       | enforce  | `/usr/sbin/spctl --master-enable`  |
    /// | **OFF**      | bypass   | `/usr/sbin/spctl --master-disable` |
    ///
    /// Both write routes — the deferred-queue builder
    /// (`FeatureCoordinator.command(for:pending:)`) and the immediate path
    /// (`FeatureCoordinator.writeGatekeeper`) — call this function, so they cannot drift
    /// into inverting each other, and the off-Mac harness copies it verbatim to assert the
    /// table (`tests/MacProfileTests.swift`). Never invert this at a call site.
    static func gatekeeperShell(enabling: Bool) -> String {
        "\(spctlTool) --master-\(enabling ? "enable" : "disable")"
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

        // (2a) The AppleScript handed to osascript, **verbatim**. An unbalanced quote or an
        // unescaped backslash inside the elevated command would fail as an opaque AppleScript
        // error, and the AppleScript text is the only place that failure is visible.
        Trace.batch("runAsAdmin: osascript -e [\(Trace.escaped(script))]")
        Trace.batch("runAsAdmin: elevated command [\(Trace.escaped(command))] timeout=\(Int(timeout))s")

        let result: ProcessResult
        do {
            result = try run(osascript, ["-e", script], timeout: timeout)
        } catch {
            Trace.batch("runAsAdmin: LAUNCH FAILED — [\(Trace.escaped(shortDescription(of: error)))]")
            return .failure(message: shortDescription(of: error), exitCode: -1)
        }

        // (2b) The raw result, with control characters made visible. `standardOutput` is
        // exactly the string `parseBatchMarkers` later scans for `RS_OK:`/`RS_FAIL:` lines, so
        // this is the one line that can prove a marker was emitted, corrupted, or never
        // produced at all.
        Trace.batch("runAsAdmin: exit=\(result.exitCode)")
        Trace.batch("runAsAdmin: stdout=[\(Trace.escaped(result.standardOutput))]")
        Trace.batch("runAsAdmin: stderr=[\(Trace.escaped(result.standardError))]")

        if result.isSuccess {
            return .success(output: result.standardOutput)
        }
        // osascript reports a dismissed dialog as "execution error: User canceled. (-128)".
        if result.standardError.contains("-128") || result.standardError.lowercased().contains("user canceled") {
            Trace.batch("runAsAdmin: outcome=cancelled (-128)")
            return .cancelled
        }
        Trace.batch("runAsAdmin: outcome=failure exit=\(result.exitCode)")
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
        guard commands.isEmpty == false else {
            Trace.batch("runBatched: called with 0 commands — nothing to do")
            return BatchResult(items: [])
        }

        let privileged = commands.filter { $0.requiresAdmin }
        let unprivileged = commands.filter { $0.requiresAdmin == false }

        // (1) What was staged, and how each row is going to be carried out. Logged **before**
        // anything runs, so a batch that never reaches its own outcome (a hang, a crash, a
        // password dialog that swallows the app) still leaves a record of what it was asked
        // to do.
        Trace.batch("runBatched: begin total=\(commands.count) privileged=\(privileged.count) unprivileged=\(unprivileged.count)")
        for command in commands {
            let kind = command.shell == nil ? "inline" : "shell"
            Trace.batch("runBatched: staged id=\(command.marker) requiresAdmin=\(command.requiresAdmin) work=\(kind) timeout=\(Int(command.timeout))s")
            if let script = command.shell {
                Trace.batch("runBatched:   staged script=[\(Trace.escaped(script))]")
            }
        }
        Trace.batch("runBatched: os=\(Trace.osVersionText()) arch=\(CPUArchitecture.current.displayName)")

        var items: [BatchItemResult] = []

        // --- One Authorization dialog for every privileged command -----------------------
        if privileged.isEmpty == false {
            let script = batchScript(for: privileged)
            // The batch lives or dies by its slowest member: a Rosetta 2 install alongside
            // three toggles must not be cut off at the 30 s default.
            let timeout = privileged.map { $0.timeout }.max() ?? defaultTimeout
            // (2) The batch script **verbatim**, before it is handed to osascript. This is the
            // only way to tell "the shell ran and the marker never came back" from "the shell
            // text itself is wrong" — both surface to the user as an identical silent no-op.
            Trace.batch("runBatched: elevated batch script (verbatim) >>>[\(Trace.escaped(script))]<<<")
            let outcome = runAsAdmin(script, timeout: timeout)

            switch outcome {
            case .cancelled:
                Trace.batch("runBatched: elevated group cancelled — no command in the batch runs, including the unprivileged half")
                // The user dismissed the dialog, which is itself the answer. **Nothing in the
                // batch runs** — including the unprivileged half. Running the LaunchAgent write
                // here while Gatekeeper silently did not change would produce exactly the
                // half-applied state the queue exists to prevent: the user said "not now" to
                // the whole set, so every row reports cancelled and Apply can be pressed again.
                let cancelled = commands.map {
                    BatchItemResult(feature: $0.feature, outcome: .cancelled)
                }
                for item in cancelled {
                    Trace.batch("runBatched: parsed item id=\(item.feature.rawValue) outcome=cancelled")
                }
                return BatchResult(items: cancelled)
            case .failure(let message, _):
                // The elevated shell itself failed (bad AppleScript, launch failure,
                // timeout). No marker can be trusted, so no privileged row is reported as
                // succeeded — but the unprivileged ones are independent and still run.
                Trace.batch("runBatched: elevated group failed — [\(Trace.escaped(message))]; no privileged marker can be trusted")
                items += privileged.map {
                    BatchItemResult(feature: $0.feature,
                                    outcome: .failure(message: message, exitCode: -1))
                }
            case .success(let output):
                Trace.batch("runBatched: elevated group returned success; parsing markers now")
                items += parseBatchMarkers(output, commands: privileged)
            }
        } else {
            Trace.batch("runBatched: no privileged command in this batch — the Authorization dialog will not appear")
        }

        // --- Unprivileged commands, no prompt ---------------------------------------------
        // (3) Entry into the non-elevated half. Hidden Files runs here, and it is the row that
        // produced no visible effect on the test machine, so its path is logged as a narrative:
        // entry → defaults write → AppleScript → Finder refresh → outcome.
        Trace.batch("runBatched: unprivileged group begin count=\(unprivileged.count)")
        for command in unprivileged {
            Trace.batch("runBatched: unprivileged running id=\(command.marker) kind=\(command.shell == nil ? "inline" : "shell")")
            let outcome: CommandOutcome
            switch command.work {
            case .inline(let work):
                outcome = work()
            case .shell(let script):
                outcome = runShell(script, timeout: command.timeout)
            }
            items.append(BatchItemResult(feature: command.feature, outcome: outcome))
            Trace.batch("runBatched: unprivileged done id=\(command.feature.rawValue) success=\(outcome.isSuccess)"
                        + (outcome.failureMessage.map { " failureMessage=[\(Trace.escaped($0))]" } ?? ""))
        }

        // (2c) The parsed `BatchItemResult` list — what the rest of the app will now show the
        // user. Logged here rather than at the view so it reflects the coordinator's decision
        // even when the UI is the menu-bar mini panel.
        Trace.batch("runBatched: end items=\(items.count)")
        for item in items {
            Trace.batch("runBatched: parsed item id=\(item.feature.rawValue) succeeded=\(item.succeeded)"
                        + (item.outcome.failureMessage.map { " message=[\(Trace.escaped($0))]" } ?? ""))
        }
        Trace.batch("runBatched: allSucceeded=\(items.allSatisfy { $0.succeeded })")

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
                } else if line == "\(batchFailPrefix)\(command.marker)" {
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

    /// AppleScript steps that make Finder re-read its preferences **without restarting**.
    ///
    /// ## Why not `killall Finder`
    ///
    /// The original implementation was `defaults write … ; killall Finder`. That works, and
    /// it is why this row was documented as "restarts Finder" — but it kills the process
    /// every Finder window lives in, so the Dock and desktop blink out and back, every
    /// window's scroll position and open-tab state is lost, and anything mid-download in a
    /// window restarts. That is a large, visible side effect for a boolean preference.
    /// `killall` must never come back.
    ///
    /// ## The ordered refresh chain (Phase 11.4)
    ///
    /// The Phase 11 single script — `tell application "Finder" to update every window` —
    /// failed on the owner's 14.7.4 machine with AppleScript error `-1708` ("every window
    /// doesn't understand the update message"): the preference was written (read-back
    /// confirmed) but open windows stayed stale. The refresh is now an **ordered chain of
    /// three steps**, each executed inside its own `try`, first success wins:
    ///
    /// 1. `tell application "Finder" to update (target of every window)`
    /// 2. a per-window loop — `repeat with w in windows`, each body wrapped in its own
    ///    `try update (target of w)` so one broken window cannot abort the rest
    /// 3. `tell application "Finder" to update (path to home folder)`
    ///
    /// The winning step is logged through `Trace.batch`, and so is each loser with its full
    /// error dictionary (a TCC refusal `-1743` and a genuinely missing Finder window must
    /// stay separable in the log). A follow-up commit prunes the losing steps after the
    /// owner field-verifies the winner on 14.7.4 and on 26. No step restarts Finder and no
    /// step needs a password.
    ///
    /// ## Automation permission (unchanged)
    ///
    /// Controlling Finder is a TCC-protected operation, so on a first run macOS may prompt
    /// for permission to "control Finder". The prompt is honest about what is being asked
    /// and declining it does not break the toggle — the preference is still written, and a
    /// Finder launched later will honour it. When *all* three steps fail the caller
    /// therefore reports **success with a note** (`finderRefreshFailedNote`) rather than a
    /// failure, because the setting really was applied.
    ///
    /// - Returns: `nil` when a step refreshed Finder; the Thai+English note when every
    ///   step failed.
    private static func refreshFinderWindows() -> String? {
        let steps: [(name: String, source: String)] = [
            ("every-window", """
            tell application "Finder" to update (target of every window)
            """),
            ("per-window-loop", """
            tell application "Finder"
                repeat with w in windows
                    try
                        update (target of w)
                    end try
                end repeat
            end tell
            """),
            ("home-folder", """
            tell application "Finder" to update (path to home folder)
            """)
        ]

        for step in steps {
            // (3c) The exact source handed to NSAppleScript, per step. An empty source here
            // would be the single most explanatory line in the whole log: it would mean the
            // Finder-refresh branch never ran, which matches "no Automation permission
            // prompt ever appeared".
            Trace.batch("hiddenFiles: refresh step [\(step.name)] source >>>[\(Trace.escaped(step.source))]<<<")
            guard let script = NSAppleScript(source: step.source) else {
                Trace.batch("hiddenFiles: refresh step [\(step.name)] — NSAppleScript(source:) returned nil (the source did not compile)")
                continue
            }
            var errorInfo: NSDictionary?
            // `executeAndReturnError` rather than `executeAndReturnResult`: we care whether
            // the tell block succeeded, not what it returned.
            let returned = script.executeAndReturnError(&errorInfo)
            // (3d) The full error dictionary, not just its message. The message alone hides
            // the two failure modes that look identical from the outside: a TCC refusal
            // (`-1743 not authorized`) and a genuinely missing Finder window, and they call
            // for completely different conclusions about whether the preference was written
            // at all. A step that fails is logged and the chain moves on to the next one.
            if let errorInfo = errorInfo {
                Trace.batch("hiddenFiles: refresh step [\(step.name)] FAILED errorInfo=[\(Trace.escaped(String(describing: errorInfo)))]")
                continue
            }
            // Plain `.stringValue`, not `?.`: on macOS `executeAndReturnError` returns a
            // **non-optional** `NSAppleEventDescriptor`, so optional chaining is a compile
            // error there. (`NSAppleScript` succeeded at this point in any case — the branch
            // is only reached when the error dictionary is nil.)
            Trace.batch("hiddenFiles: refresh step [\(step.name)] WON — Finder refreshed"
                        + " returned=[\(Trace.escaped(returned.stringValue ?? "<no string value>"))]")
            return nil
        }

        Trace.batch("hiddenFiles: every refresh step failed — the preference is written, open windows stay stale")
        return finderRefreshFailedNote
    }

    /// The success-with-note text shown when the preference was written but no refresh
    /// step could reach Finder (Phase 11.4).
    ///
    /// Thai first (owner-mandated copy), English second — the same pairing as the other
    /// owner-owned strings. Surfaced through the status banner on both commit routes
    /// (panel batch and immediate menu action), never as a failure: the setting really was
    /// applied, only the visible refresh did not happen.
    static let finderRefreshFailedNote =
        "รีเฟรชไม่สำเร็จ กรุณากด ⌘⇧. ใน Finder หรือเปิดหน้าต่างใหม่ / Press ⌘⇧. in Finder or reopen the window"

    /// Shows or hides dotfiles in Finder, **without restarting Finder**.
    ///
    /// This is feature 3's single write path, called identically from the panel's deferred
    /// queue and the menu-bar item — there is exactly one implementation, so the routes
    /// cannot drift (the same reason `FeatureCoordinator.command(for:pending:)` is the one
    /// command table).
    ///
    /// The preference write is still `defaults`, deliberately: it is unprivileged, it is the
    /// same key `SystemStateReader.areHiddenFilesShown()` reads back, and it keeps the
    /// durable truth independent of Finder being scriptable. The ordered AppleScript chain
    /// (`refreshFinderWindows()`) is layered on afterwards purely to make running windows
    /// notice.
    ///
    /// - Parameter shown: `true` reveals dotfiles, matching the row's ON == shown semantics.
    /// - Returns: success with an **empty** output when a refresh step reached Finder;
    ///   success carrying `finderRefreshFailedNote` when the preference was written but the
    ///   whole chain failed — a note, never a failure, because the setting really was
    ///   applied. A failure is returned only when the *write* failed.
    static func setHiddenFilesShown(_ shown: Bool) -> CommandOutcome {
        Trace.batch("hiddenFiles: begin shown=\(shown)")
        let command = "\(finderDefaultsTool) write com.apple.finder AppleShowAllFiles "
            + (shown ? "YES" : "NO")
        Trace.batch("hiddenFiles: running [\(Trace.escaped(command))]")
        let write = runShell(command)
        // (3a) The **exit status** of the defaults write, and both streams. This is the load
        // bearing step of the whole row: everything after it is cosmetic, so "written but
        // invisible" and "never written" have to be separable here.
        Trace.batch("hiddenFiles: defaults write success=\(write.isSuccess)"
                    + (write.failureMessage.map { " message=[\(Trace.escaped($0))]" } ?? "")
                    + " output=[\(Trace.escaped(write.output))]")
        // Read the key straight back, so the log carries the value macOS now holds rather
        // than the value the app asked for.
        let readBack = (try? SystemCommands.run(finderDefaultsTool,
                                               ["read", "com.apple.finder", "AppleShowAllFiles"]))
            .map { "exit=\($0.exitCode) raw=[\(Trace.escaped($0.standardOutput))]" } ?? "unavailable"
        Trace.batch("hiddenFiles: read-back AppleShowAllFiles \(readBack)")
        guard write.isSuccess else {
            Trace.batch("hiddenFiles: aborting before the Finder refresh — the write failed")
            return write
        }

        Trace.batch("hiddenFiles: write succeeded — attempting the ordered Finder refresh chain")
        if let problem = refreshFinderWindows() {
            // The preference is written and will apply to the next Finder window, so this is
            // a success with a note rather than a failure. `problem` is the Thai+English
            // note itself; the caller surfaces it through the status banner.
            Trace.log("hidden files: preference written, Finder refresh chain exhausted (\(problem))")
            Trace.batch("hiddenFiles: end success-with-note refresh=all-steps-failed")
            return .success(output: problem)
        }
        Trace.batch("hiddenFiles: end success refresh=ok")

        // Post-refresh verification: read back the key to confirm the value macOS now holds.
        // Both directions matter. The previous diagnostic treated only "shown == true" as
        // verified, so a successful hide operation was logged as a failure-like state.
        let postReadBack = (try? SystemCommands.run(finderDefaultsTool,
                                               ["read", "com.apple.finder", "AppleShowAllFiles"]))
            .map { $0.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            ?? ""
        let postShown = parseDefaultsBool(postReadBack)
        Trace.batch("post-refresh verification: AppleShowAllFiles raw=[\(Trace.escaped(postReadBack))]"
                    + " parsed=\(postShown.map(String.init) ?? "nil") expected=\(shown)")

        guard postShown == shown else {
            Trace.batch("hiddenFiles: post-refresh verification FAILED — preference read-back did not match the requested value")
            return .failure(
                message: "Hidden Files preference was written, but macOS read-back did not match the requested value.",
                exitCode: -1)
        }
        return .success(output: "")
    }

    /// Path to `defaults`, the one place the Hidden Files write path names it.
    ///
    /// The immediate routes and the deferred-queue route both build their command through
    /// `FeatureCoordinator.command(for:pending:)`, so this constant exists to keep a second
    /// spelling of the path from creeping into either of them.
    private static let finderDefaultsTool = "/usr/bin/defaults"

    private static func parseDefaultsBool(_ value: String) -> Bool? {
        let raw = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if raw == "1" || raw == "true" || raw == "yes" { return true }
        if raw == "0" || raw == "false" || raw == "no" { return false }
        return nil
    }

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
