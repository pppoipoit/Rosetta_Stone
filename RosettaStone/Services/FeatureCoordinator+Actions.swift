import Foundation

/// The eight feature operations from `docs/FEATURES.md`, in their fixed row order.
///
/// Split from the coordinator's state machinery purely for file size; the type is
/// still a single class, so the serial-queue guarantee is unaffected.
///
/// Command strings are built from **constants only**. No user input, URL parameter or
/// runtime-discovered file name is ever interpolated into a command — that is what
/// makes `osascript … with administrator privileges` safe to drive from a URL scheme.
extension FeatureCoordinator {

    /// Paths to the tools used by the write paths.
    ///
    /// Internal rather than `private` because `FeatureCoordinator.command(for:pending:)` — the
    /// deferred-queue builder — needs the same constants. One table of paths means the queued
    /// route and the immediate routes cannot drift to different binaries.
    ///
    /// `defaults` is **deliberately absent**. The Hidden Files write moved in Phase 11 into
    /// `SystemCommands.setHiddenFilesShown(_:)`, which owns its path constant next to the
    /// AppleScript refresh that has to run with it. A second spelling of the path here would
    /// invite the two to drift, and a row that writes one preference domain while reading
    /// another is exactly the bug that surfaces as "the toggle does nothing".
    enum Tool {
        static let spctl = "/usr/sbin/spctl"
        static let killall = "/usr/bin/killall"
        static let nvram = "/usr/sbin/nvram"
        static let softwareupdate = "/usr/sbin/softwareupdate"
        static let mdutil = "/usr/bin/mdutil"
        static let dscacheutil = "/usr/bin/dscacheutil"
        static let rm = "/bin/rm"
    }

    // MARK: - 1. Run at Startup  (admin)

    /// Executes one command from the table, on whichever path it declares.
    ///
    /// The single place that knows how a `FeatureCommand`'s work is carried out, so the
    /// immediate routes (`runImmediately`, `setHiddenFiles`, `toggleHiddenFiles`) cannot each
    /// grow their own slightly different interpretation of `.inline` versus `.shell`. The
    /// batch runner does its own dispatch because it has to split by privilege first, but it
    /// runs the same two cases.
    ///
    /// `requiresAdmin` is honoured here rather than at each call site: a command that says it
    /// needs root gets `runAsAdmin`, which is what raises the Authorization dialog.
    ///
    /// Must be called from inside a locked operation (i.e. from `perform`'s work closure).
    private static func run(_ command: FeatureCommand) -> CommandOutcome {
        switch command.work {
        case .inline(let work):
            return work()
        case .shell(let script):
            return command.requiresAdmin
                ? SystemCommands.runAsAdmin(script, timeout: command.timeout)
                : SystemCommands.runShell(script, timeout: command.timeout)
        }
    }

    /// Runs one staged-style change immediately, through the **same** command table the
    /// deferred queue uses (`command(for:pending:)`).
    ///
    /// This is why there is exactly one place that knows what `spctl --master-disable` looks
    /// like. The panel stages a change and the queue batches it; the menu bar and the URL
    /// scheme run one immediately — and all four routes build their shell from one function,
    /// so they cannot drift to different commands.
    ///
    /// The macOS 15+ Gatekeeper follow-up is deliberately **not** fired from here: it belongs
    /// to the write path's caller, because the batch needs to fire it only after parsing
    /// markers, and `setGatekeeper` fires it itself.
    private func runImmediately(_ feature: FeatureID,
                                pending: PendingChange,
                                successMessage: String?) {
        perform(feature,
                successMessage: successMessage,
                work: {
                    guard let command = self.command(for: feature, pending: pending) else {
                        return .failure(message: "\(feature.displayName) is not available on this Mac.",
                                        exitCode: -1)
                    }
                    return FeatureCoordinator.run(command)
                })
    }

    /// Installs or removes `~/Library/LaunchAgents/com.rosettastone.helper.plist`.
    func setRunAtStartup(_ enabled: Bool) {
        runImmediately(.runAtStartup,
                       pending: .toggle(enabled),
                       successMessage: enabled
                           ? "Rosetta Stone will start automatically at every login."
                           : "The login item has been removed.")
    }

    // MARK: - 2. Gatekeeper  (admin)

    /// ON == **bypassed**. The inverted semantics are deliberate: the switch shows what
    /// has actually been disabled rather than a vague "on".
    ///
    /// ## macOS 15+ is a two-step procedure
    ///
    /// On Sequoia (15) — and Tahoe (26) and Golden Gate (27) after it — the CLI command
    /// alone no longer flips the user-visible switch: the user must also choose
    /// **Anywhere** in System Settings. `writeGatekeeper(bypassed:)` runs the command and
    /// then hands the confirmation to the UI, which opens the pane and explains the step
    /// (`GatekeeperPolicy`). Re-enabling (`--master-enable`) is one step everywhere and
    /// never triggers the confirmation.
    func setGatekeeper(bypassed: Bool) {
        // Not `runImmediately`: `writeGatekeeper` owns the macOS 15+ System Settings
        // follow-up, which must run after the command succeeds and never after a failure.
        perform(.gatekeeper,
                successMessage: bypassed
                    ? "Gatekeeper is now bypassed. Re-enable it when you no longer need it."
                    : "Gatekeeper is active again.",
                work: { [weak self] in
                    self?.writeGatekeeper(bypassed: bypassed)
                        ?? .failure(message: "App is shutting down.", exitCode: -1)
                })
    }

    /// The single write path for feature 2, shared by the switch, the menu and the URL
    /// scheme so the macOS 15+ follow-up can never be skipped on one of them.
    ///
    /// Runs on the coordinator's serial queue (inside `perform`). The user-facing
    /// follow-up is dispatched to the main thread through `publish`, never called inline.
    private func writeGatekeeper(bypassed: Bool) -> CommandOutcome {
        let outcome = SystemCommands.runAsAdmin(
            "\(Tool.spctl) --master-\(bypassed ? "disable" : "enable")")

        // Only after a successful *disable* on macOS 15+ does System Settings need the
        // user's hand. A failed command must not open System Settings: the failure
        // message and a "go pick Anywhere" instruction would contradict each other.
        // (5) Same instrumentation as the batch route: the hook's presence and whether it
        // fired. These two call sites are the only places the follow-up can be raised, and a
        // difference between them is exactly what the log is here to reveal.
        Trace.batch("writeGatekeeper: outcome=\(outcome.isSuccess ? "success" : "not-success")"
                    + " bypassed=\(bypassed)"
                    + " versionGate=\(SystemCommands.gatekeeperDisableRequiresSystemSettingsConfirmation())"
                    + " hookInstalled=\(onGatekeeperNeedsConfirmation != nil)")
        if case .success = outcome,
           bypassed,
           SystemCommands.gatekeeperDisableRequiresSystemSettingsConfirmation() {
            Trace.batch("writeGatekeeper: FIRING onGatekeeperNeedsConfirmation (immediate route)")
            publish { $0.onGatekeeperNeedsConfirmation?() }
        } else {
            Trace.batch("writeGatekeeper: NOT firing onGatekeeperNeedsConfirmation (immediate route)")
        }
        return outcome
    }

    // MARK: - 3. Hidden Files  (no elevation)

    /// The only feature that never prompts for a password.
    ///
    /// Finder is **not** restarted (Phase 11): the write goes through
    /// `SystemCommands.setHiddenFilesShown(_:)`, which writes the preference and then tells
    /// running Finder windows to re-read it. Previously this row issued `killall Finder`,
    /// which made the Dock and desktop blink and discarded every window's state for a
    /// boolean preference.
    ///
    /// The immediate route still goes through the shared command table, so the menu-bar item
    /// and a queued batch write byte-identical commands.
    func setHiddenFiles(shown: Bool) {
        perform(.hiddenFiles,
                successMessage: shown
                    ? "Hidden files are now visible in Finder."
                    : "Hidden files are now hidden.",
                work: { [weak self] in
                    guard let command = self?.command(for: .hiddenFiles, pending: .toggle(shown)) else {
                        return .failure(message: "Could not build the hidden-files command.", exitCode: -1)
                    }
                    return FeatureCoordinator.run(command)
                })
    }

    // MARK: - 4. Auto Boot  (admin, Intel only)

    /// Writes the NVRAM `AutoBoot` variable: `%03` = enabled, `%00` = disabled — the
    /// 3-digit zero-padded binary the firmware expects (`%03` is the Intel default for
    /// "auto boot on"; `%01` is tolerated on read for machines already carrying it).
    ///
    /// Guarded twice, and the two guards are deliberately different questions:
    ///
    /// 1. **`availability(for:)`** — the full `MacProfile` rule: Intel **and** a lid. This is
    ///    what the row itself is greyed out by, so the user never reaches this method.
    /// 2. **The Intel check below** — defense in depth. The write path is also reachable
    ///    without touching the UI, and the *only* unconditional hardware error it can make
    ///    is an `nvram` write to Apple Silicon firmware, where the variable does not exist
    ///    and NVRAM is reset on every cold boot. That check stays narrow on purpose: it is
    ///    the invariant that must hold even if the profile is ever wrong or unrecognised,
    ///    so it is written as a literal rather than delegating back to the profile.
    func setAutoBoot(enabled: Bool) {
        // Intel-only, stated independently of `MacProfile`.
        guard profile.cpuArchitecture == .x86_64 else {
            report("Auto Boot cannot be changed on \(architecture.displayName) — M-series firmware "
                 + "owns the AutoBoot setting and its NVRAM is reset on every cold boot.",
                   style: .failure)
            return
        }

        guard availability(for: .autoBoot).isEnabled else {
            let reason = profile.autoBootDisabledReason
                ?? "no lid, or the model could not be identified"
            report("Auto Boot is not available on this Mac — \(reason).", style: .failure)
            return
        }

        runImmediately(.autoBoot,
                       pending: .toggle(enabled),
                       successMessage: enabled ? "Auto boot is enabled." : "Auto boot is disabled.")
    }

    // MARK: - Toggles used by the URL scheme and the menu-bar menu
    //
    // These read the current state and write its opposite. The read has to happen
    // *inside* the locked operation, not before it: doing the read in a separate
    // `queue.async` and then calling `perform` would leave a window in which another
    // operation could change the same feature, and the toggle would then write a stale
    // opposite value.

    /// Flips Gatekeeper to the opposite of whatever is currently configured.
    func toggleGatekeeper() {
        perform(.gatekeeper,
                successMessage: nil, // the real message depends on the direction
                work: { [weak self] in
                    guard let self = self else { return .failure(message: "App is shutting down.", exitCode: -1) }
                    let currentlyBypassed = SystemStateReader.isGatekeeperBypassed()
                    let target = (currentlyBypassed ?? false) == false
                    // `report(_:style:)` rather than assigning `statusMessage` directly:
                    // the property is `private(set)`, and that setter is scoped to
                    // FeatureCoordinator.swift, so this file — a separate file — could
                    // not assign it even though it is the same type.
                    self.report(
                        target
                            ? "Gatekeeper is now bypassed. Re-enable it when you no longer need it."
                            : "Gatekeeper is active again.",
                        style: .success)
                    // Shared with `setGatekeeper`, so the macOS 15+ System Settings step
                    // also runs for the menu-bar click and the URL action.
                    return self.writeGatekeeper(bypassed: target)
                })
    }

    /// Flips hidden-file visibility in Finder.
    ///
    /// Shared with `setHiddenFiles(shown:)` through the command table, so the menu-bar item
    /// and a queued batch write byte-identical commands.
    func toggleHiddenFiles() {
        perform(.hiddenFiles,
                successMessage: nil,
                work: { [weak self] in
                    guard let self = self else { return .failure(message: "App is shutting down.", exitCode: -1) }
                    let target = SystemStateReader.areHiddenFilesShown() == false
                    // See `toggleGatekeeper()` for why this goes through `report`.
                    self.report(
                        target
                            ? "Hidden files are now visible in Finder."
                            : "Hidden files are now hidden.",
                        style: .success)
                    guard let command = self.command(for: .hiddenFiles, pending: .toggle(target)) else {
                        return .failure(message: "Could not build the hidden-files command.", exitCode: -1)
                    }
                    return FeatureCoordinator.run(command)
                })
    }

    // MARK: - 5. Rosetta 2  (admin, Apple Silicon only)

    /// Installs the Rosetta 2 translator. Takes several minutes, hence the long timeout.
    ///
    /// Idempotent by pre-check: when the runtime is already on disk the user is never
    /// prompted for a password at all.
    func installRosetta() {
        guard availability(for: .rosetta2).isEnabled else {
            report("Rosetta 2 runs on Apple Silicon only — this Mac is \(architecture.displayName).",
                   style: .failure)
            return
        }
        // Already on disk: succeed without ever raising a password dialog.
        guard SystemStateReader.isRosettaInstalled() == false else {
            perform(.rosetta2, successMessage: nil,
                    work: { .success(output: "Already installed.") })
            return
        }
        runImmediately(.rosetta2,
                       pending: .action,
                       successMessage: "Rosetta 2 is installed.")
    }

    // MARK: - 6. Spotlight Rebuild  (admin)

    /// Erases the Spotlight index for the startup volume. `mdutil -E /` returns as soon
    /// as the erase is scheduled — the rebuild itself continues for minutes afterwards.
    func rebuildSpotlight() {
        runImmediately(.spotlightRebuild,
                       pending: .action,
                       successMessage: "Spotlight is rebuilding its index. This takes several minutes.")
    }

    // MARK: - 7. DNS Flush  (admin)

    /// **Order matters**: the resolver cache is flushed *before* mDNSResponder is
    /// signalled, otherwise the daemon reloads with the stale cache still in place.
    ///
    /// A missing `mDNSResponder` exits non-zero; "cache flushed" is the success criterion,
    /// so that error is suppressed.
    func flushDNS() {
        runImmediately(.dnsFlush,
                       pending: .action,
                       successMessage: "The DNS cache has been flushed.")
    }

    // MARK: - 8. Clear System Cache  (admin)

    /// The highest-risk action in the app. The UI confirms before calling this, and the
    /// macOS auth prompt follows — the confirmation is deliberately *additional*, never
    /// a replacement (`docs/FEATURES.md` §8).
    ///
    /// The `*` glob is intentional: it does not match dotfiles, and switching to a form
    /// that does would risk removing the directory's own metadata.
    func clearSystemCache() {
        runImmediately(.clearSystemCache,
                       pending: .action,
                       successMessage: "The system cache has been cleared. Caches rebuild as apps need them.")
    }
}
