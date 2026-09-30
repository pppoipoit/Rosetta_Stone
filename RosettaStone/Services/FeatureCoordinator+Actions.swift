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
    private enum Tool {
        static let spctl = "/usr/sbin/spctl"
        static let defaults = "/usr/bin/defaults"
        static let killall = "/usr/bin/killall"
        static let nvram = "/usr/sbin/nvram"
        static let softwareupdate = "/usr/sbin/softwareupdate"
        static let mdutil = "/usr/bin/mdutil"
        static let dscacheutil = "/usr/bin/dscacheutil"
        static let rm = "/bin/rm"
    }

    // MARK: - 1. Run at Startup  (admin)

    /// Installs or removes `~/Library/LaunchAgents/com.rosettastone.helper.plist`.
    func setRunAtStartup(_ enabled: Bool) {
        perform(.runAtStartup,
                successMessage: enabled
                    ? "Rosetta Stone will start automatically at every login."
                    : "The login item has been removed.",
                work: { enabled ? self.startupManager.install() : self.startupManager.remove() })
    }

    // MARK: - 2. Gatekeeper  (admin)

    /// ON == **bypassed**. The inverted semantics are deliberate: the switch shows what
    /// has actually been disabled rather than a vague "on".
    func setGatekeeper(bypassed: Bool) {
        perform(.gatekeeper,
                successMessage: bypassed
                    ? "Gatekeeper is now bypassed. Re-enable it when you no longer need it."
                    : "Gatekeeper is active again.",
                work: {
                    SystemCommands.runAsAdmin("\(Tool.spctl) --master-\(bypassed ? "disable" : "enable")")
                })
    }

    // MARK: - 3. Hidden Files  (no elevation)

    /// The only feature that never prompts for a password.
    ///
    /// `killall Finder` restarts Finder; the desktop and Dock blink out and back. Expected,
    /// documented in the panel, and harmless to this app's own window.
    func setHiddenFiles(shown: Bool) {
        perform(.hiddenFiles,
                successMessage: shown
                    ? "Hidden files are now visible in Finder."
                    : "Hidden files are now hidden.",
                work: {
                    SystemCommands.runShell("""
                    \(Tool.defaults) write com.apple.finder AppleShowAllFiles \(shown ? "YES" : "NO") && \
                    \(Tool.killall) Finder
                    """)
                })
    }

    // MARK: - 4. Auto Boot  (admin, Intel only)

    /// Writes the NVRAM `AutoBoot` variable: `%01` = enabled, `%00` = disabled — the
    /// 3-digit zero-padded binary the firmware expects.
    ///
    /// Guarded twice: the UI disables the row on Apple Silicon, and this guard protects
    /// the URL-scheme path, which can be invoked without touching the UI at all.
    func setAutoBoot(enabled: Bool) {
        guard availability(for: .autoBoot).isEnabled else {
            report("Auto Boot is not available on \(architecture.displayName) — this Mac has no AutoBoot NVRAM variable.",
                   style: .failure)
            return
        }
        perform(.autoBoot,
                successMessage: enabled ? "Auto boot is enabled." : "Auto boot is disabled.",
                work: {
                    SystemCommands.runAsAdmin("\(Tool.nvram) AutoBoot=\(enabled ? "%01" : "%00")")
                })
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
                    return SystemCommands.runAsAdmin(
                        "\(Tool.spctl) --master-\(target ? "disable" : "enable")")
                })
    }

    /// Flips hidden-file visibility in Finder.
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
                    return SystemCommands.runShell("""
                    \(Tool.defaults) write com.apple.finder AppleShowAllFiles \(target ? "YES" : "NO") && \
                    \(Tool.killall) Finder
                    """)
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
        perform(.rosetta2,
                successMessage: "Rosetta 2 is installed.",
                work: {
                    guard SystemStateReader.isRosettaInstalled() == false else {
                        return .success(output: "Already installed.")
                    }
                    return SystemCommands.runAsAdmin(
                        "\(Tool.softwareupdate) --install-rosetta --agree-to-license",
                        timeout: SystemCommands.longTimeout)
                })
    }

    // MARK: - 6. Spotlight Rebuild  (admin)

    /// Erases the Spotlight index for the startup volume. `mdutil -E /` returns as soon
    /// as the erase is scheduled — the rebuild itself continues for minutes afterwards.
    func rebuildSpotlight() {
        perform(.spotlightRebuild,
                successMessage: "Spotlight is rebuilding its index. This takes several minutes.",
                work: { SystemCommands.runAsAdmin("\(Tool.mdutil) -E /") })
    }

    // MARK: - 7. DNS Flush  (admin)

    /// **Order matters**: the resolver cache is flushed *before* mDNSResponder is
    /// signalled, otherwise the daemon reloads with the stale cache still in place.
    ///
    /// A missing `mDNSResponder` exits non-zero; "cache flushed" is the success criterion,
    /// so that error is suppressed.
    func flushDNS() {
        perform(.dnsFlush,
                successMessage: "The DNS cache has been flushed.",
                work: {
                    SystemCommands.runAsAdmin("""
                    \(Tool.dscacheutil) -flushcache && \
                    (\(Tool.killall) -HUP mDNSResponder 2>/dev/null || true)
                    """)
                })
    }

    // MARK: - 8. Clear System Cache  (admin)

    /// The highest-risk action in the app. The UI confirms before calling this, and the
    /// macOS auth prompt follows — the confirmation is deliberately *additional*, never
    /// a replacement (`docs/FEATURES.md` §8).
    ///
    /// The `*` glob is intentional: it does not match dotfiles, and switching to a form
    /// that does would risk removing the directory's own metadata.
    func clearSystemCache() {
        perform(.clearSystemCache,
                successMessage: "The system cache has been cleared. Caches rebuild as apps need them.",
                work: { SystemCommands.runAsAdmin("\(Tool.rm) -rf /Library/Caches/*") })
    }
}
