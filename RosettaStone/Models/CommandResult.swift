import Foundation

/// The raw result of an **unprivileged** child process.
///
/// Nothing in Rosetta Stone reads a command's exit status alone — the authoritative
/// state is always re-read afterwards (see `FeatureCoordinator.finish`). This type
/// merely carries what the shell reported so the coordinator can decide.
struct ProcessResult {

    /// stdout, trimmed and truncated to `SystemCommands.maxOutputBytes`.
    let standardOutput: String

    /// stderr, trimmed and truncated to `SystemCommands.maxOutputBytes`.
    let standardError: String

    /// Termination status. `0` means success by convention only.
    let exitCode: Int32

    var isSuccess: Bool { exitCode == 0 }

    /// stderr if present, otherwise stdout — what should be shown to the user on failure.
    var diagnosticText: String {
        if !standardError.isEmpty { return standardError }
        if !standardOutput.isEmpty { return standardOutput }
        return "Command exited with status \(exitCode) and produced no output."
    }
}

/// The three terminal states of every Rosetta Stone action.
///
/// `docs/FEATURES.md` → "Feedback": every action ends in exactly one of these.
/// No action may fail silently, and a cancelled authentication dialog is *not* an error.
enum CommandOutcome {

    /// Exit status 0.
    case success(output: String)

    /// The user dismissed the macOS Authorization dialog (`osascript` reports AppleScript
    /// error `-128`, "User canceled."). Callers must revert silently — **no** alert.
    case cancelled

    /// Non-zero exit, launch failure or timeout. `message` is user-presentable.
    case failure(message: String, exitCode: Int32)

    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }

    /// Non-nil only for `.failure`.
    var failureMessage: String? {
        if case .failure(let message, _) = self { return message }
        return nil
    }

    /// Output of a successful command (empty string otherwise).
    var output: String {
        if case .success(let output) = self { return output }
        return ""
    }
}
