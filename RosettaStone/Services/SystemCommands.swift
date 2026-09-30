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
        if let commandError = error as? CommandError { return commandError.errorDescription }
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
