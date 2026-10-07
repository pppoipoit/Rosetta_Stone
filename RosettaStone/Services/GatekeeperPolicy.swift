import Foundation

/// The observable state of feature 2, as the user experiences it.
///
/// ## Why a state machine and not a `Bool?`
///
/// `spctl --master-disable` **succeeding is not the same as Gatekeeper being bypassed**
/// from macOS 15 onwards. The command flips the command-line assessment state; the
/// user-visible switch in System Settings ("Allow applications from: **Anywhere**") is a
/// separate confirmation the app cannot perform — System Settings is not scriptable for
/// this control, and automating a security downgrade would be indistinguishable from
/// malware. Reporting "Bypassed" the instant the command exits 0 is therefore a **lie**:
/// the command-line checks are off, System Settings still says "App Store and known
/// developers", and unsigned tools still refuse to run.
///
/// So the coordinator tracks three real-world states plus an explicit unknown:
///
/// ```
///   disable command        user clicks "Anywhere"        spctl --status == disabled
///  ───────────────▶ .pendingConfirmation ─────────────▶ .bypassed
///       ▲                                                    │
///       └──────────────── spctl --master-enable ◀────────────┘
/// ```
///
/// - `.active` — `spctl --status` reports assessments enabled. Nothing pending.
/// - `.pendingConfirmation` — **this app** ran `spctl --master-disable` on macOS 15+ and
///   `spctl --status` still reports *enabled*. The UI says so and points at System Settings;
///   it must never claim "Bypassed".
/// - `.bypassed` — `spctl --status` reports assessments disabled. Confirmed by a read,
///   never inferred from an exit code.
/// - `.unknown` — the status could not be read. Kept distinct from `.active` on purpose:
///   an unreadable status is never reported as a protected machine (`docs/FEATURES.md` §2).
///
/// `.pendingConfirmation` is only ever entered by *this* process having run the disable
/// command; a fresh launch on a machine where the user already clicked "Anywhere" reads
/// `.bypassed` straight from `spctl`.
enum GatekeeperState: Equatable {

    /// `spctl --status` → "assessments enabled".
    case active

    /// The disable command ran, but the System Settings confirmation is still outstanding.
    case pendingConfirmation

    /// `spctl --status` → "assessments disabled". Verified by a read, not inferred.
    case bypassed

    /// The status could not be read at all. Not the same as `.active`.
    case unknown

    /// The row's on/off value. `nil` keeps "could not read" out of the switch entirely.
    var isBypassed: Bool? {
        switch self {
        case .bypassed:                     return true
        case .active, .pendingConfirmation: return false
        case .unknown:                      return nil
        }
    }

    /// Whether the app is waiting on the human in System Settings.
    var isAwaitingUserConfirmation: Bool { self == .pendingConfirmation }

    /// Diagnostics label.
    var displayName: String {
        switch self {
        case .active:              return "active"
        case .pendingConfirmation: return "pending confirmation in System Settings"
        case .bypassed:            return "bypassed"
        case .unknown:             return "unknown (spctl --status unreadable)"
        }
    }

    /// Derives the state from a `spctl --status` read plus whether a disable is outstanding.
    ///
    /// - Parameters:
    ///   - reportedBypassed: `SystemStateReader.isGatekeeperBypassed()` — `nil` when the
    ///     command failed or its output was unrecognised.
    ///   - disablePending: `true` only while *this process* has run `spctl --master-disable`
    ///     on a version that requires the System Settings step and has not yet seen the
    ///     state flip. Touched only on the coordinator's serial queue.
    ///
    /// A reported `true` always wins: the user clicked "Anywhere", the machine reached the
    /// end of the journey, and the pending marker is retired by the caller.
    static func resolve(reportedBypassed: Bool?, disablePending: Bool) -> GatekeeperState {
        if reportedBypassed == true { return .bypassed }
        if disablePending { return .pendingConfirmation }
        if reportedBypassed == false { return .active }
        return .unknown
    }
}

/// The OS-follow-up copy and deep link for **disabling** Gatekeeper (feature 2, ON
/// direction).
///
/// ## Why the version matters
///
/// macOS 15 Sequoia — and macOS 26 Tahoe and macOS 27 Golden Gate after it — no longer
/// let `spctl --master-disable` finish the job on its own. The command still flips the
/// command-line assessment state, but the **user-visible** switch in System Settings
/// (“Allow applications from: Anywhere”) has to be confirmed by the user. The version rule
/// itself lives in `SystemCommands.gatekeeperDisableRequiresSystemSettingsConfirmation`
/// (it is about what the command does on this OS); this type owns the user-facing half:
///
/// 1. `FeatureCoordinator` runs `spctl --master-disable` (admin) exactly as before,
/// 2. the deep link below opens System Settings at the Security page, and
/// 3. `confirmationMessage` is the instruction shown next to it.
///
/// Between step 1 and the user acting, the coordinator publishes
/// `GatekeeperState.pendingConfirmation` — never "Bypassed" — and polls `spctl --status`
/// until the state settles. See `GatekeeperState`.
///
/// Re-enabling never triggers this flow.
///
/// The confirmation copy is Thai by owner decision; the rest of the app is English.
enum GatekeeperPolicy {

    /// Deep link to the **Security** section of System Settings — the page that carries
    /// “Allow applications from: Anywhere” alongside the FileVault and firewall entries.
    ///
    /// ## Why the bare pane and not `?Privacy_AllFiles`
    ///
    /// The previous value was
    /// `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`. That
    /// anchor opens the **Privacy tab, scrolled down to Full Disk Access** — a different
    /// control entirely, and one this app has no business touching. It sent the user to a
    /// permission list where “Anywhere” does not exist, which is the difference between a
    /// one-click confirmation and an impossible one. The anchor is dropped entirely: the
    /// target is the Security *page*, and macOS has always landed there at the top, which
    /// is where the switch lives.
    ///
    /// The legacy `com.apple.preference.security` pane identifier is used on purpose:
    /// it is honoured on every supported macOS from 10.15 through 27, whereas the
    /// Ventura+ `com.apple.settings.PrivacySecurity.extension` spelling is unrecognised
    /// on the 10.15 floor.
    static let settingsURL = "x-apple.systempreferences:com.apple.preference.security"

    /// The exact instruction shown after the command succeeds on macOS 15+.
    static let confirmationMessage =
        "กรุณาเลือก 'Anywhere' ใน System Settings เพื่อยืนยันการปิด Gatekeeper"

    /// Toast shown while the state machine sits in `.pendingConfirmation`.
    ///
    /// Distinct from `confirmationMessage` on purpose: the alert is the one-shot prompt
    /// raised at the moment the command succeeds, while this is what the status item and
    /// the panel footer keep saying for as long as `spctl --status` still reports
    /// *enabled*. It says **pending**, never **bypassed** — the whole point of P1 #3.
    static let pendingMessage =
        "Gatekeeper: กรุณาเลือก 'Anywhere' ใน System Settings เพื่อยืนยัน — ยังไม่ถูกปิด"

    /// Shown once the state machine reaches `.bypassed` after a pending period.
    static let confirmedMessage =
        "Gatekeeper is now bypassed. Re-enable it when you no longer need it."

    /// The grey "unknown" tooltip on the Gatekeeper row (Phase 11.4).
    ///
    /// Shown when `spctl --status` could not be parsed — before Phase 11.4 the same fact
    /// was carried by the header status dot's grey state, which the owner removed. Thai
    /// first (owner copy), English second. The row keeps working: the tooltip says the app
    /// does not know the state, it does not block the switch or guess a direction.
    static let unknownTooltip =
        "อ่านสถานะ Gatekeeper ไม่ได้ / Cannot read Gatekeeper state"
}
