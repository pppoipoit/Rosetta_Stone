import Foundation

/// Unprivileged readers for every piece of state the panel displays.
///
/// Split out of `FeatureCoordinator` so that the "read" side of the app has exactly one
/// home: no view, and no write path, ever calls `spctl`, `nvram` or `defaults` directly.
/// **None of these functions can prompt for a password** — that is the invariant that
/// lets the app be opened for free (`docs/ARCHITECTURE.md` §4).
enum SystemStateReader {

    /// Paths to the tools that are only ever *read* here.
    enum Tool {
        static let spctl = "/usr/sbin/spctl"
        static let defaults = "/usr/bin/defaults"
        static let nvram = "/usr/sbin/nvram"
        /// The Rosetta 2 runtime binary. Its presence is the authoritative install check.
        static let rosettaRuntime = "/usr/libexec/oah/libRosettaRuntime"
    }

    /// `spctl --status` → "assessments disabled" means Gatekeeper is bypassed.
    ///
    /// Returns `nil` when the status could not be read — an unknown is never reported as
    /// OFF, which would misrepresent a managed machine as a protected one.
    static func isGatekeeperBypassed() -> Bool? {
        guard let result = try? SystemCommands.run(Tool.spctl, ["--status"]), result.isSuccess else { return nil }
        let output = result.standardOutput.lowercased()
        if output.contains("assessments disabled") { return true }
        if output.contains("assessments enabled") { return false }
        return nil
    }

    /// `defaults read com.apple.finder AppleShowAllFiles` → 1 = shown, 0 = hidden.
    ///
    /// A missing key exits non-zero ("does not exist") and means "the system default",
    /// which is hidden — so a read failure is OFF here, unlike Gatekeeper, where the
    /// equivalent unknown is deliberately preserved (`docs/FEATURES.md` §3).
    static func areHiddenFilesShown() -> Bool {
        guard let result = try? SystemCommands.run(Tool.defaults,
                                                   ["read", "com.apple.finder", "AppleShowAllFiles"]),
              result.isSuccess else { return false }
        let value = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value == "1" || value == "true" || value == "yes"
    }

    /// `nvram AutoBoot` → `%01` enabled, `%00` disabled, no output or an unexpected
    /// value → `nil` ("unknown"), surfaced in the UI rather than coerced to a boolean.
    static func isAutoBootEnabled() -> Bool? {
        guard let result = try? SystemCommands.run(Tool.nvram, ["AutoBoot"]), result.isSuccess else { return nil }
        let output = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { return nil }
        if output.contains("%01") { return true }
        if output.contains("%00") { return false }
        return nil
    }

    /// Whether the Rosetta 2 runtime is present on disk.
    ///
    /// This filesystem probe — not `uname -m` — is the authoritative answer: an Apple
    /// Silicon Mac already running under Rosetta reports `x86_64` from `uname -m`, which
    /// would wrongly grey out the Install button.
    static func isRosettaInstalled() -> Bool {
        FileManager.default.fileExists(atPath: Tool.rosettaRuntime)
    }

    /// Whether Spotlight indexing is switched off for `/`. When it is, `mdutil -E /`
    /// silently does nothing, so the UI warns before the user waits for a rebuild
    /// that will never happen (`docs/FEATURES.md` §6).
    static func isSpotlightIndexingEnabled() -> Bool {
        guard let result = try? SystemCommands.run("/usr/bin/mdutil", ["-s", "/"]), result.isSuccess else {
            return true // assume the common case rather than blocking the user
        }
        let output = result.standardOutput.lowercased()
        return !output.contains("indexing disabled")
    }
}
