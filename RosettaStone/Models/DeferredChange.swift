import Foundation

/// What the user asked for on a row, recorded but **not yet applied**.
///
/// The panel is a **staging area**, not a control panel: toggling a switch does not run a
/// command, it records an intent. The queue is committed by the two master buttons at the
/// bottom of the panel (ADR-009).
///
/// ## Why an enum and not `[FeatureID: Any]`
///
/// A heterogeneous `[FeatureID: Any]` dictionary forces every read back through a cast
/// (`as? Bool`), and a mis-cast silently degrades to "no pending change" — the user stages a
/// change, presses Apply, and nothing happens. Three small cases carry no ambiguity and are
/// exhaustively checkable in one switch.
enum PendingChange: Equatable {

    /// A toggle was flipped. The payload is the value the user wants, in the row's own
    /// semantics (Gatekeeper since Phase 11.4: `true` == **enforcing**, i.e. the switch ON;
    /// Hidden Files: `true` == shown; the rest: `true` == the feature enabled).
    case toggle(Bool)

    /// A one-shot action button was pressed (Rosetta 2, Spotlight, DNS Flush, Clear Cache).
    ///
    /// No payload: there is nothing to compare against, so the row is pending for exactly as
    /// long as the entry exists.
    case action
}

/// One unit of work the deferred queue can commit.
///
/// Deliberately a **value** rather than a closure: batching needs to group commands by
/// privilege, decide which ones share a single Authorization dialog, and report a per-item
/// result — all of which require inspecting what the command *is* before running it.
struct FeatureCommand {

    /// How the work is actually performed.
    enum Work {
        /// A `/bin/sh` fragment, run either as the user or through the elevated batch.
        case shell(String)

        /// In-process work with no shell at all — the LaunchAgent plist is written with
        /// `FileManager` because it lives in the user's own home directory (ADR-006).
        case inline(() -> CommandOutcome)
    }

    /// The row this command belongs to. Doubles as the batch output marker.
    let feature: FeatureID

    let work: Work

    /// `true` when the work goes through the batch's single `with administrator privileges`
    /// prompt. Only these share one Authorization dialog.
    let requiresAdmin: Bool

    /// Wall-clock budget. A batch containing Rosetta 2 inherits `longTimeout`.
    var timeout: TimeInterval = SystemCommands.defaultTimeout

    /// Unprivileged shell run **once for the whole batch**, and only if this command
    /// succeeded — the "finish the job after the write" slot.
    ///
    /// Introduced for `killall Finder`, which had to run once per batch rather than once per
    /// row so a queue touching four things did not blink the desktop four times. Phase 11
    /// removed that need by refreshing Finder through AppleScript instead, so **nothing sets
    /// this today**. The mechanism is retained deliberately: it is the only place in the
    /// batch runner that understands "this step belongs to the batch, not to the row", and
    /// the next feature that needs that should not have to re-derive the sequencing (or
    /// discover the ordering bug that per-row execution invites).
    var batchPostStep: String?

    init(feature: FeatureID,
         work: Work,
         requiresAdmin: Bool,
         timeout: TimeInterval = SystemCommands.defaultTimeout,
         batchPostStep: String? = nil) {
        self.feature = feature
        self.work = work
        self.requiresAdmin = requiresAdmin
        self.timeout = timeout
        self.batchPostStep = batchPostStep
    }

    /// The token that identifies this command in the batch script's output.
    ///
    /// Derived from `FeatureID.rawValue` rather than supplied, so a command can never be
    /// reported under a marker that does not match its row, and marker parsing can match
    /// **exactly** — `install-rosetta` is never a prefix-match for anything else.
    var marker: String { feature.rawValue }

    /// The shell fragment, or `nil` for inline work.
    var shell: String? {
        if case .shell(let script) = work { return script }
        return nil
    }
}

/// The result of committing one row in a batch.
struct BatchItemResult {

    let feature: FeatureID
    let outcome: CommandOutcome

    var succeeded: Bool { outcome.isSuccess }
}

/// The outcome of a whole batch — one entry per committed command, in submission order.
///
/// Order is preserved deliberately. A dictionary would render the results dialog in a
/// nondeterministic order, so "what happened" would not match "what I pressed".
///
/// `Identifiable` so the panel can present it with `.sheet(item:)`; the id is derived from the
/// item count and the features involved, so a re-run of the same queue is a distinct sheet.
struct BatchReport: Identifiable {

    let items: [BatchItemResult]

    var id: String {
        items.map { "\($0.feature.rawValue):\($0.succeeded)" }.joined(separator: "|")
    }

    init(items: [BatchItemResult]) {
        self.items = items
    }

    var isEmpty: Bool { items.isEmpty }

    var allSucceeded: Bool { items.allSatisfy { $0.succeeded } }

    /// True when the Authorization dialog was dismissed.
    ///
    /// Cancellation is not an error (`docs/FEATURES.md` → Feedback): every command in the
    /// elevated group reports `.cancelled` and nothing is reported as broken.
    var wasCancelled: Bool {
        items.contains { item in
            if case .cancelled = item.outcome { return true }
            return false
        }
    }

    /// The rows that did not succeed, for the per-item results dialog.
    var failures: [BatchItemResult] { items.filter { $0.succeeded == false } }

    func outcome(for feature: FeatureID) -> CommandOutcome? {
        for item in items where item.feature == feature { return item.outcome }
        return nil
    }
}