import Foundation

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
/// 2. the deep link below opens System Settings at Privacy & Security, and
/// 3. `confirmationMessage` is the instruction shown next to it.
///
/// Re-enabling never triggers this flow.
///
/// The confirmation copy is Thai by owner decision; the rest of the app is English.
enum GatekeeperPolicy {

    /// Deep link to **System Settings → Privacy & Security**, where the “Anywhere”
    /// option appears once `spctl --master-disable` has run.
    ///
    /// The legacy `com.apple.preference.security` pane identifier is used on purpose:
    /// it is honoured on every supported macOS from 10.15 through 27, whereas the
    /// Ventura+ `com.apple.settings.PrivacySecurity.extension` spelling is unrecognised
    /// on the 10.15 floor.
    static let settingsURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"

    /// The exact instruction shown after the command succeeds on macOS 15+.
    static let confirmationMessage =
        "กรุณาเลือก 'Anywhere' ใน System Settings เพื่อยืนยันการปิด Gatekeeper"
}
