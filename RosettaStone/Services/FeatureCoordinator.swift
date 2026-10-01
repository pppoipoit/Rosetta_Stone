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

    let architecture: CPUArchitecture
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

    /// The authoritative in-flight marker, touched **only** on `queue`.
    ///
    /// The single-operation lock must be decided on the serial queue. Deciding it from
    /// the `@Published busyFeature` would be racy: that value is written on the main
    /// thread, so a URL action dispatched straight onto `queue` could read a stale
    /// `nil` and start a second `osascript` prompt alongside the first.
    private var activeFeature: FeatureID?

    // MARK: - Init

    init(architecture: CPUArchitecture = .current) {
        self.architecture = architecture
    }

    // MARK: - Availability (derived from the cached CPU detection)

    func availability(for feature: FeatureID) -> FeatureAvailability {
        feature.availability(on: architecture)
    }

    /// True while any operation is in flight.
    var isBusy: Bool { busyFeature != nil }

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
                    text: "“\(running.title)” is still running — please wait for it to finish.",
                    style: .info) }
                return
            }

            self.activeFeature = feature
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
