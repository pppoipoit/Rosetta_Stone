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
    /// thread, so a URL action dispatched straight onto `queue` could read a stale
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
    /// blocks the shortcuts: a URL action must not slip in beside a live Authorization dialog.
    var isBusy: Bool { busyFeature != nil || isApplyingBatch }

    // MARK: - Initial state load

    /// Reads every feature's state, unprivileged. Called once at launch.
    func loadState() {
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
    /// Lives beside the other write paths so the *immediate* routes (menu bar, URL scheme) and
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

        case (.gatekeeper, .toggle(let bypassed)):
            return FeatureCommand(
                feature: feature,
                work: .shell("\(Tool.spctl) --master-\(bypassed ? "disable" : "enable")"),
                requiresAdmin: true)

        case (.hiddenFiles, .toggle(let shown)):
            // `killall Finder` is deliberately **not** part of the command: it runs once for
            // the whole batch (see `batchPostStep`), so a queue that also touches three other
            // rows does not blink the desktop three times.
            return FeatureCommand(
                feature: feature,
                work: .shell("\(Tool.defaults) write com.apple.finder AppleShowAllFiles \(shown ? "YES" : "NO")"),
                requiresAdmin: false,
                batchPostStep: "\(Tool.killall) Finder")

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
        guard commands.isEmpty == false else { return }

        queue.async { [weak self] in
            guard let self = self else { return }

            if let running = self.activeFeature {
                self.publish { $0.statusMessage = StatusMessage(
                    text: running.title.map { "“\($0)” is still running — please wait for it to finish." }
                        ?? "Changes are still being applied — please wait.",
                    style: .info) }
                return
            }

            self.activeFeature = .batch
            self.publish { $0.isApplyingBatch = true }

            let result = SystemCommands.runBatched(commands)
            let report = BatchReport(items: result.items)

            // Post-steps run once for the whole batch, and only for rows that actually
            // succeeded. `killall Finder` after a failed hidden-files write would restart
            // Finder for nothing and blink at a setting that never changed.
            let succeeded = Set(result.items.filter { $0.succeeded }.map { $0.feature })
            var ranPostSteps: Set<String> = []
            for command in commands where succeeded.contains(command.feature) {
                guard let step = command.batchPostStep, ranPostSteps.insert(step).inserted else { continue }
                _ = SystemCommands.runShell(step)
            }

            // The macOS 15+ Gatekeeper follow-up still runs, but **only** if the batch actually
            // disabled Gatekeeper successfully. Opening System Settings after a failed or
            // cancelled `spctl` would contradict the message the user is looking at.
            if case .success? = report.outcome(for: .gatekeeper),
               SystemStateReader.isGatekeeperBypassed() == true,
               SystemCommands.gatekeeperDisableRequiresSystemSettingsConfirmation() {
                self.publish { $0.onGatekeeperNeedsConfirmation?() }
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
                    coordinator.statusMessage = StatusMessage(
                        text: "สำเร็จทั้งหมด · \(report.items.count) change(s) applied.",
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
        // this from the UI, from a URL, and — for the toggle URL actions — from `queue`
        // itself, so the guard has to be correct regardless of which queue it is run on.
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
    /// refusing a URL-driven action that the current CPU does not support.
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
