import Foundation
import Combine

/// The observable state owner for the whole panel.
///
/// Design notes, all from `docs/ARCHITECTURE.md` §1:
///
/// - **Reads and writes are separated.** Reads are always unprivileged (see
///   `SystemStateReader`), so opening the window never costs a password dialog.
/// - **One serial queue owns every state-mutating operation.** Two simultaneous
///   `osascript` prompts would fight for focus, and read-modify-write sequences
///   (`nvram AutoBoot`) must not interleave.
/// - **Never trust the exit code.** After every write the authoritative state is
///   re-read, so an MDM policy that snaps Gatekeeper back on is reflected rather than
///   optimistically shown as success.
/// - **Views never spawn processes.** They call methods here and observe `@Published`.
///
/// The eight feature methods live in `FeatureCoordinator+Actions.swift`.
final class FeatureCoordinator: ObservableObject {

    // MARK: - Published state

    /// Feature 1. ON == the LaunchAgent plist exists.
    @Published private(set) var runAtStartup = false

    /// Feature 2. ON == Gatekeeper is **disabled** (inverted — the switch shows what you
    /// have actually turned off). `nil` means "could not read", which is not the same as OFF.
    @Published private(set) var gatekeeperBypassed: Bool?

    /// Feature 3. ON == hidden files are **shown** (inverted vs. the system default).
    @Published private(set) var hiddenFilesShown = false

    /// Feature 4. ON == auto boot enabled. `nil` means the NVRAM variable is unset or
    /// holds an unrecognised value.
    @Published private(set) var autoBootEnabled: Bool?

    /// Feature 5. From the `libRosettaRuntime` probe, not from `uname -m`.
    @Published private(set) var rosettaInstalled = false

    /// True while any feature row is busy — used to show the in-flight state.
    @Published private(set) var busyFeature: FeatureID?

    /// True while a **deferred batch** is being committed (ADR-009).
    ///
    /// Separate from `busyFeature` on purpose: a batch spans several rows, so there is no
    /// single row to spin, and naming one of them would be a lie. The panel uses this to grey
    /// out the master buttons and the whole grid while a single Authorization dialog is up.
    @Published private(set) var isApplyingBatch = false

    /// The last completed action's feedback, shown in the panel footer.
    @Published private(set) var statusMessage: StatusMessage?

    /// A warning that persists until the condition is resolved (stale login item).
    @Published private(set) var warning: String?

    // MARK: - Supporting types

    /// The three visual states of a footer message.
    ///
    /// Conforms to `Equatable` so the containing `StatusMessage` can too: SwiftUI's
    /// `.sheet(item:)` and `Button` labels diff against the presented value, and a
    /// non-`Equatable` style would make `StatusMessage: Equatable` fail to synthesise.
    enum StatusStyle: Equatable {
        case success, failure, info
    }

    struct StatusMessage: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let style: StatusStyle
    }

    // MARK: - Dependencies

    /// What this Mac **is** — the model name, the form factor derived from it, and the
    /// already-detected CPU architecture (ADR-008).
    ///
    /// This is the *only* hardware identity the availability rules consult. It used to be a
    /// bare `CPUArchitecture`, which could answer "Intel or Apple Silicon?" but not "does
    /// this machine have a lid?" — and Auto Boot needs both answers.
    let profile: MacProfile

    /// The host CPU, as part of `profile`. Kept as a named property because the panel header
    /// and the Diagnostics report both display it on its own.
    var architecture: CPUArchitecture { profile.cpuArchitecture }

    let startupManager = StartupManager()

    /// Serialises every state-mutating operation. Reads run here too, so a
    /// read-modify-write pair can never interleave with another operation.
    let queue = DispatchQueue(label: "com.rosettastone.coordinator")

    /// Set by `MenuBarController`: the macOS 15+ follow-up for the Gatekeeper bypass.
    ///
    /// Invoked on the **main thread** the moment `spctl --master-disable` succeeds. The
    /// UI opens System Settings and tells the user to pick “Anywhere” —
    /// `GatekeeperPolicy` owns the version rule and the copy. A closure rather than an
    /// `NSAlert` call here, because the coordinator must not import AppKit
    /// (layering rule 1, `docs/ARCHITECTURE.md` §6).
    var onGatekeeperNeedsConfirmation: (() -> Void)?

    /// What currently holds the single-operation lock, touched **only** on `queue`.
    ///
    /// A batch occupies the same lock as a single feature, because the invariant is
    /// "one privileged thing at a time", not "one row at a time". Without the `.batch` case a
    /// batch and a menu-bar toggle could each believe they had the machine to themselves and
    /// raise two Authorization dialogs at once.
    private enum ActiveOperation {
        case feature(FeatureID)
        case batch

        /// The row to name in the "still running" message, or `nil` for a batch.
        var title: String? {
            if case .feature(let feature) = self { return feature.title }
            return nil
        }
    }

    /// The authoritative in-flight marker, touched **only** on `queue`.
    ///
    /// The single-operation lock must be decided on the serial queue. Deciding it from
    /// the `@Published busyFeature` would be racy: that value is written on the main
    /// thread, so an immediate action dispatched straight onto `queue` could read a stale
    /// `nil` and start a second `osascript` prompt alongside the first.
    private var activeFeature: ActiveOperation?

    // MARK: - Init

    /// - Parameter profile: injectable so the availability rules can be exercised against
    ///   a synthetic machine without a Mac in the loop (`tests/MacProfileTests.swift`).
    init(profile: MacProfile = .current) {
        self.profile = profile
    }

    // MARK: - Availability (derived from the cached hardware profile)

    func availability(for feature: FeatureID) -> FeatureAvailability {
        feature.availability(on: profile)
    }

    /// True while any operation is in flight — a single feature **or** a batch.
    ///
    /// The menu bar disables its mutating items from exactly this, so a queued batch also
    /// blocks them: an immediate action must not slip in beside a live Authorization dialog.
    var isBusy: Bool { busyFeature != nil || isApplyingBatch }

    // MARK: - State resync (truth-first, Phase 11.4)

    /// Reads every feature's state, unprivileged.
    ///
    /// Resync triggers, all funnelled through here so the log can say *why* a read
    /// happened (`docs/ARCHITECTURE.md` §6, "Two layers of state"):
    ///
    /// 1. **launch** — `AppDelegate.applicationDidFinishLaunching`,
    /// 2. **app/window didBecomeActive** — `AppDelegate` observes
    ///    `NSApplication.didBecomeActiveNotification`, so a state that changed while the
    ///    panel was in the background (System Settings, an MDM policy, a terminal command)
    ///    is re-read the moment the user comes back,
    /// 3. **after every Apply** — `applyBatch` ends in `reloadState()`,
    /// 4. **after every CANCEL** — both panels' `cancelPendingChanges()` call this,
    /// 5. **after every single-operation terminal state** — `finish` calls `reloadState()`,
    ///    cancellation included.
    ///
    /// - Parameter reason: free-text trigger label, logged before the read. Rows without a
    ///   staged change display exactly these values; rows with a staged change keep the
    ///   staged value and their orange dot until Apply/CANCEL.
    func loadState(_ reason: String = "unspecified") {
        Trace.batch("loadState: requested (\(reason))")
        queue.async { [weak self] in
            self?.reloadState()
        }
    }

    /// Re-reads all state and republishes it on the main thread.
    /// Also called after every write, so the UI always shows reality.
    private func reloadState() {
        let startup = startupManager.isInstalled()
        let stale = startup && startupManager.hasStaleExecutablePath()
        let gatekeeper = SystemStateReader.isGatekeeperBypassed()
        let hidden = SystemStateReader.areHiddenFilesShown()
        let autoBoot = SystemStateReader.isAutoBootEnabled()
        let rosetta = SystemStateReader.isRosettaInstalled()

        // (4) The macOS **major version** plus the values every read above resolved to.
        // The version is logged because two behaviours are version-gated — the Gatekeeper
        // two-step (>= 15) and the Hidden Files AppleScript refresh — and a report of "nothing
        // happened" is uninterpretable without knowing which side of those gates the host is on.
        Trace.batch("reloadState: macOS=\(Trace.osVersionText()) major=\(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)"
                    + " gatekeeper=\(gatekeeper.map(String.init) ?? "nil") hiddenFiles=\(hidden)"
                    + " autoBoot=\(autoBoot.map(String.init) ?? "nil") rosetta=\(rosetta) startup=\(startup) stale=\(stale)")
        Trace.batch("reloadState: gatekeeper disable requires System Settings confirmation ="
                    + " \(SystemCommands.gatekeeperDisableRequiresSystemSettingsConfirmation())")

        publish { coordinator in
            coordinator.runAtStartup = startup
            coordinator.gatekeeperBypassed = gatekeeper
            coordinator.hiddenFilesShown = hidden
            coordinator.autoBootEnabled = autoBoot
            coordinator.rosettaInstalled = rosetta
            coordinator.warning = stale
                ? "The login item points at an app that has moved. Turn Run at Startup off and on again to repair it."
                : nil
        }
    }

    // MARK: - The deferred queue (ADR-009)

    /// Translates one staged change into the command that will commit it.
    ///
    /// Lives beside the other write paths so the *immediate* route (menu bar) and
    /// the *queued* route cannot drift: both ultimately call the same `SystemCommands`
    /// primitives with the same strings. Returns `nil` for a change that has no command —
    /// a locked row, or a one-shot action that is already satisfied.
    ///
    /// - Parameter pending: the staged intent for `feature`.
    func command(for feature: FeatureID, pending: PendingChange) -> FeatureCommand? {
        switch (feature, pending) {

        case (.runAtStartup, .toggle(let enabled)):
            // No elevation, and no shell either: the plist lives in the user's own home
            // directory, so this is a `FileManager` call (ADR-006). Running it inside the
            // batch as *inline* work is what keeps the "no password for your own ~/Library"
            // guarantee intact while still batching it with everything else.
            return FeatureCommand(
                feature: feature,
                work: .inline { [weak self] in
                    guard let self = self else {
                        return .failure(message: "App is shutting down.", exitCode: -1)
                    }
                    return enabled ? self.startupManager.install() : self.startupManager.remove()
                },
                requiresAdmin: false)

        case (.gatekeeper, .toggle(let enforcing)):
            // ON == enforce (Phase 11.4 owner spec): the switch shows the protection, not
            // what has been turned off. The mapping itself lives in one function so this
            // route and `writeGatekeeper` cannot invert each other — the off-Mac harness
            // asserts it (`tests/MacProfileTests.swift`).
            return FeatureCommand(
                feature: feature,
                work: .shell(SystemCommands.gatekeeperShell(enabling: enforcing)),
                requiresAdmin: true)

        case (.hiddenFiles, .toggle(let shown)):
            // **Inline**, not shell (Phase 11): the write plus the AppleScript refresh runs
            // in-process. There is no post-step any more — `batchPostStep` existed only to
            // hold `killall Finder`, and the AppleScript path removes the need to restart
            // Finder at all, so a batch no longer blinks the desktop.
            return FeatureCommand(
                feature: feature,
                work: .inline { SystemCommands.setHiddenFilesShown(shown) },
                requiresAdmin: false)

        case (.autoBoot, .toggle(let enabled)):
            // Same two guards as `setAutoBoot(enabled:)`. A staged change on a locked row can
            // only happen if the Mac changed identity between staging and applying, so it is
            // refused rather than written.
            guard profile.cpuArchitecture == .x86_64,
                  availability(for: .autoBoot).isEnabled else { return nil }
            return FeatureCommand(
                feature: feature,
                work: .shell("\(Tool.nvram) AutoBoot=\(enabled ? "%03" : "%00")"),
                requiresAdmin: true)

        case (.rosetta2, .action):
            guard availability(for: .rosetta2).isEnabled else { return nil }
            // Pre-check, exactly as `installRosetta()` does: never raise a password dialog to
            // install something that is already on disk.
            guard SystemStateReader.isRosettaInstalled() == false else { return nil }
            return FeatureCommand(
                feature: feature,
                work: .shell("\(Tool.softwareupdate) --install-rosetta --agree-to-license"),
                requiresAdmin: true,
                timeout: SystemCommands.longTimeout)

        case (.spotlightRebuild, .action):
            return FeatureCommand(
                feature: feature,
                work: .shell("\(Tool.mdutil) -E /"),
                requiresAdmin: true)

        case (.dnsFlush, .action):
            return FeatureCommand(
                feature: feature,
                work: .shell("""
                \(Tool.dscacheutil) -flushcache && \
                (\(Tool.killall) -HUP mDNSResponder 2>/dev/null || true)
                """),
                requiresAdmin: true)

        case (.clearSystemCache, .action):
            return FeatureCommand(
                feature: feature,
                work: .shell("\(Tool.rm) -rf /Library/Caches/*"),
                requiresAdmin: true)

        default:
            return nil
        }
    }

    /// Commits a whole queue under the same single-operation lock every other write uses.
    ///
    /// Guarantees, all inherited from `perform`:
    /// 1. a batch requested while another operation is running is **rejected**, never
    ///    interleaved — two Authorization dialogs must never fight for focus,
    /// 2. the panel shows one busy state,
    /// 3. exactly one terminal outcome per row,
    /// 4. authoritative state is re-read afterwards, so a pending dot clears only for rows
    ///    that actually took effect.
    ///
    /// - Parameter completion: receives the per-item results so the view can raise its
    ///   results dialog. Called on the **main thread**.
    func applyBatch(_ commands: [FeatureCommand],
                    completion: @escaping (BatchReport) -> Void) {
        guard commands.isEmpty == false else {
            Trace.batch("applyBatch: called with 0 commands — nothing to do")
            return
        }

        // (1) Every staged command with its `requiresAdmin` flag, logged here — the **entry
        // point** of the batch, before the lock is even taken. The view hands over commands
        // only; it never sees the flag, so a row silently landing in the wrong privilege group
        // would otherwise be invisible until it failed.
        Trace.batch("applyBatch: \(commands.count) command(s) staged")
        for command in commands {
            Trace.batch("applyBatch: staged id=\(command.marker) requiresAdmin=\(command.requiresAdmin)"
                        + " postStep=\(command.batchPostStep.map { "[\($0)]" } ?? "none")")
        }

        queue.async { [weak self] in
            guard let self = self else { return }

            if let running = self.activeFeature {
                Trace.batch("applyBatch: REJECTED — an operation is already in flight (\(running.title ?? "batch"))")
                self.publish { $0.statusMessage = StatusMessage(
                    text: running.title.map { "“\($0)” is still running — please wait for it to finish." }
                        ?? "Changes are still being applied — please wait.",
                    style: .info) }
                return
            }

            Trace.batch("applyBatch: lock acquired (.batch); starting SystemCommands.runBatched")
            self.activeFeature = .batch
            self.publish { $0.isApplyingBatch = true }

            let result = SystemCommands.runBatched(commands)
            let report = BatchReport(items: result.items)

            // Post-steps run once for the whole batch, and only for rows that actually
            // succeeded. Nothing sets `batchPostStep` today — it was introduced to hold
            // `killall Finder` (Phase 11 replaced that with an AppleScript refresh), and
            // the mechanism is kept because the next feature needing "finish the job after
            // the write" should not have to re-invent the sequencing.
            let succeeded = Set(result.items.filter { $0.succeeded }.map { $0.feature })
            var ranPostSteps: Set<String> = []
            for command in commands where succeeded.contains(command.feature) {
                guard let step = command.batchPostStep, ranPostSteps.insert(step).inserted else { continue }
                _ = SystemCommands.runShell(step)
            }

            // The macOS 15+ Gatekeeper follow-up still runs, but **only** if the batch actually
            // disabled Gatekeeper successfully. Opening System Settings after a failed or
            // cancelled `spctl` would contradict the message the user is looking at.
            // (5) Logged at each step: the hook's existence, the three conditions it is gated
            // on, and whether it actually fired. A silent no-op here is the reason the
            // System Settings follow-up never appeared.
            let gatekeeperOutcome = report.outcome(for: .gatekeeper)
            Trace.batch("applyBatch: gatekeeper follow-up — hook installed=\(self.onGatekeeperNeedsConfirmation != nil)"
                        + " outcome=\(gatekeeperOutcome.map { $0.isSuccess ? "success" : "not-success" } ?? "absent from batch")")
            let bypassedNow = SystemStateReader.isGatekeeperBypassed()
            Trace.batch("applyBatch: gatekeeper follow-up — spctl now bypassed=\(bypassedNow.map(String.init) ?? "nil")"
                        + " versionGate=\(SystemCommands.gatekeeperDisableRequiresSystemSettingsConfirmation())")
            if case .success? = gatekeeperOutcome,
               bypassedNow == true,
               SystemCommands.gatekeeperDisableRequiresSystemSettingsConfirmation() {
                Trace.batch("applyBatch: FIRING onGatekeeperNeedsConfirmation")
                self.publish { $0.onGatekeeperNeedsConfirmation?() }
                Trace.batch("applyBatch: onGatekeeperNeedsConfirmation dispatched")
            } else {
                Trace.batch("applyBatch: NOT firing onGatekeeperNeedsConfirmation")
            }

            // Release the lock *before* the main-thread publishes are delivered, for the same
            // reason `perform` does: the queue must not be held up by UI work.
            self.activeFeature = nil
            self.publish { coordinator in
                coordinator.isApplyingBatch = false
                if report.wasCancelled {
                    // Silent revert: the user dismissed the dialog, which is itself the answer.
                    coordinator.statusMessage = nil
                } else if report.allSucceeded {
                    // Success-with-note (Phase 11.4): if the ordered Finder refresh chain
                    // was exhausted, the Hidden Files item carries the Thai+English note as
                    // its success output. That note is the actionable half of "success", so
                    // it replaces the generic all-green line; a batch that did not touch
                    // Hidden Files keeps it unchanged.
                    let note = report.outcome(for: .hiddenFiles)?.output ?? ""
                    coordinator.statusMessage = StatusMessage(
                        text: note.isEmpty
                            ? "สำเร็จทั้งหมด · \(report.items.count) change(s) applied."
                            : note,
                        style: .success)
                } else {
                    coordinator.statusMessage = StatusMessage(
                        text: "\(report.failures.count) of \(report.items.count) change(s) could not be applied.",
                        style: .failure)
                }
            }

            // Re-read after every terminal state, so rows that took effect lose their
            // pending dot and the ones that did not keep it.
            self.reloadState()

            DispatchQueue.main.async { completion(report) }
        }
    }

    // MARK: - Operation plumbing (used by FeatureCoordinator+Actions.swift)

    /// Runs `work` on the serial queue under the single-operation lock.
    ///
    /// Every write goes through here, which guarantees:
    ///   1. a second request while one is running is **rejected**, never queued — two
    ///      simultaneous `osascript` prompts would fight for focus,
    ///   2. the row shows its in-flight state,
    ///   3. exactly one terminal status message,
    ///   4. authoritative state is re-read afterwards.
    ///
    /// - Parameters:
    ///   - feature: the row to mark busy.
    ///   - successMessage: shown on exit status 0. `nil` means "say nothing on success".
    ///   - work: performs the command; runs on `queue`, never on the main thread.
    func perform(_ feature: FeatureID,
                 successMessage: String?,
                 work: @escaping () -> CommandOutcome) {
        // The lock is taken *on the serial queue*, never on the main thread. Callers reach
        // this from the panel and from the menu-bar menu, so the guard has to be correct
        // regardless of which queue it is run on.
        // Deciding it from the `@Published busyFeature` would be racy: that value is
        // written on the main thread, so a second request could read a stale `nil` and
        // open a second Authorization dialog alongside the first.
        queue.async { [weak self] in
            guard let self = self else { return }

            if let running = self.activeFeature {
                self.publish { $0.statusMessage = StatusMessage(
                    text: running.title.map { "“\($0)” is still running — please wait for it to finish." }
                        ?? "Changes are still being applied — please wait.",
                    style: .info) }
                return
            }

            self.activeFeature = .feature(feature)
            self.publish { $0.busyFeature = feature }

            let outcome = work()

            // Release the lock *before* the main-thread publishes are delivered, so the
            // queue is never held up by UI work and the busy state cannot get stuck if a
            // publish is dropped.
            self.activeFeature = nil
            self.publish { $0.busyFeature = nil }

            self.finish(feature, outcome: outcome, successMessage: successMessage)
        }
    }

    /// Terminal state for one operation: publish one message, then re-read state.
    ///
    /// Cancellation is silent — the user already said what they wanted by dismissing the
    /// dialog, and `docs/FEATURES.md` forbids an error alert for it.
    ///
    /// The lock is released by `perform` before this is called, so this method does not
    /// touch `activeFeature` and must only be reached from inside a locked operation.
    private func finish(_ feature: FeatureID,
                        outcome: CommandOutcome,
                        successMessage: String?) {
        switch outcome {
        case .cancelled:
            // Silently revert. The user dismissed the dialog, which is itself the answer.
            publish { $0.statusMessage = nil }

        case .success:
            // `nil` means "the operation already reported its own outcome" — that is how
            // the toggle actions, whose message depends on the direction they flipped to,
            // stay correct without knowing the direction here.
            if let successMessage = successMessage {
                publish { $0.statusMessage = StatusMessage(text: successMessage, style: .success) }
            }

        case .failure(let message, _):
            publish { $0.statusMessage = StatusMessage(text: message, style: .failure) }
        }

        // Re-read after *every* terminal state, including cancellation: reality may
        // have changed either way (MDM policy, spontaneous re-enable). This runs inline
        // on the serial queue — it must not dispatch again, or a state read would be able
        // to slip in between a command finishing and the next one starting.
        reloadState()
    }

    /// Publishes a message without running a command — used for validation and for
    /// explaining why the current CPU does not support a requested action.
    func report(_ text: String, style: StatusStyle = .info) {
        publish { $0.statusMessage = StatusMessage(text: text, style: style) }
    }

    /// Applies `changes` on the main thread — `@Published` must never be mutated off it.
    func publish(_ changes: @escaping (FeatureCoordinator) -> Void) {
        if Thread.isMainThread {
            changes(self)
        } else {
            DispatchQueue.main.async { changes(self) }
        }
    }
}
