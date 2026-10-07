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
    /// ## The exit code never gates parsing (Phase 11.4)
    ///
    /// Owner evidence (Intel MacBookPro14,1, macOS 14.7.4): `spctl --status` printed
    /// `assessments disabled` **and exited 1** on an already-bypassed machine. The old
    /// reader did `guard value.isSuccess else { return nil }`, so the stdout was captured
    /// and then thrown away: the UI saw `nil`, the baseline for every staged decision was
    /// "unknown" instead of truth, and the macOS 15+ confirmation gate — which requires a
    /// parsed `true` — was silently suppressed. Parsing is therefore driven by the text
    /// only; the exit code is logged for diagnostics and otherwise ignored.
    ///
    /// Returns `nil` only when the command could not be launched or the output was
    /// unrecognised — an unknown is never reported as OFF, which would misrepresent a
    /// managed machine as a protected one.
    static func isGatekeeperBypassed() -> Bool? {
        // Captured **once**, then logged. Running the command twice here would be harmless but
        // it would double every state read for no gain — the raw output of the single run is
        // all the diagnostics need.
        let result = try? SystemCommands.run(Tool.spctl, ["--status"])
        // (4) The **raw** spctl output *and* the value parsed from it. The derived Bool only
        // says "enabled"/"disabled"; the raw line says what spctl actually printed, which is
        // what distinguishes a genuinely protected Mac from one where spctl printed something
        // unrecognised or is governed by an MDM profile.
        switch result {
        case .none:
            Trace.batch("read: spctl --status — the command could not be launched (nil)")
            return nil
        case .some(let value):
            // NOTE: no `guard value.isSuccess`. See the doc comment — exit 1 with
            // "assessments disabled" is the observed truth on 14.7.4 and must parse.
            let parsed = parseSpctlStatus(stdout: value.standardOutput)
            Trace.batch("read: spctl --status exit=\(value.exitCode)"
                        + " raw=[\(Trace.escaped(value.standardOutput))]"
                        + " stderr=[\(Trace.escaped(value.standardError))]"
                        + " parsed=\(parsed.map(String.init) ?? "nil")")
            return parsed
        }
    }

    /// Parses `spctl --status` stdout into the bypassed flag. **Exit-code agnostic.**
    ///
    /// - "assessments disabled" → `true` (Gatekeeper is bypassed)
    /// - "assessments enabled"  → `false` (Gatekeeper is enforcing)
    /// - anything else (garbage, empty output) → `nil` (unknown)
    ///
    /// Deliberately a pure function of the text with no `exitCode` parameter: the
    /// signature *is* the contract. `tests/MacProfileTests.swift` copies it verbatim and
    /// asserts both strings across exit 0 and exit 1, plus garbage and empty output.
    static func parseSpctlStatus(stdout: String) -> Bool? {
        let output = stdout.lowercased()
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
        let result = try? SystemCommands.run(Tool.defaults,
                                             ["read", "com.apple.finder", "AppleShowAllFiles"])
        guard let value = result else {
            Trace.batch("read: defaults read AppleShowAllFiles — could not be launched (nil); treated as hidden")
            return false
        }
        // (4) Raw value, same reason as `spctl` above. A non-zero exit is **normal** when the
        // key has never been written — the output is "does not exist", which is itself the
        // answer — so the raw text is logged rather than treated as an error.
        Trace.batch("read: defaults read AppleShowAllFiles exit=\(value.exitCode)"
                    + " raw=[\(Trace.escaped(value.standardOutput))]"
                    + " stderr=[\(Trace.escaped(value.standardError))]")
        guard value.isSuccess else { return false }
        let raw = value.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return raw == "1" || raw == "true" || raw == "yes"
    }

    /// `nvram AutoBoot` → `%03` enabled, `%00` disabled, no output or an unexpected
    /// value → `nil` ("unknown"), surfaced in the UI rather than coerced to a boolean.
    ///
    /// `%01` is also accepted as **enabled**: some Intel firmware reports the older
    /// value, and reading it as OFF would invite the user to "fix" a setting that is
    /// already correct.
    static func isAutoBootEnabled() -> Bool? {
        guard let result = try? SystemCommands.run(Tool.nvram, ["AutoBoot"]), result.isSuccess else { return nil }
        let output = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { return nil }
        if output.contains("%03") || output.contains("%01") { return true }
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
