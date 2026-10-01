import Foundation

/// The eight capabilities defined in `docs/FEATURES.md`, in their fixed row order.
///
/// `rawValue` doubles as the URL-scheme host for the actions that are exposed
/// (`rosettastone://toggle-gatekeeper` → `.gatekeeper`), so the two tables cannot drift.
enum FeatureID: String, CaseIterable {
    case runAtStartup       = "run-at-startup"
    case gatekeeper         = "toggle-gatekeeper"
    case hiddenFiles        = "toggle-hidden-files"
    case autoBoot           = "auto-boot"
    case rosetta2           = "install-rosetta"
    case spotlightRebuild   = "rebuild-spotlight"
    case dnsFlush           = "flush-dns"
    case clearSystemCache   = "clear-cache"

    /// Row label as shown in the panel.
    var title: String {
        switch self {
        case .runAtStartup:     return "Run at Startup"
        case .gatekeeper:       return "Gatekeeper"
        case .hiddenFiles:      return "Hidden Files"
        case .autoBoot:         return "Auto Boot"
        case .rosetta2:         return "Rosetta 2"
        case .spotlightRebuild: return "Rebuild Spotlight"
        case .dnsFlush:         return "Flush DNS"
        case .clearSystemCache: return "Clear System Cache"
        }
    }
}

/// Whether a row is interactive on this Mac, and why not if it is not.
///
/// Unavailable rows are **greyed out, never hidden** — the padlock explains the
/// absence instead of making the app look broken (`docs/ARCHITECTURE.md` §5).
struct FeatureAvailability {

    let isEnabled: Bool

    /// Non-nil when the row is locked; surfaced as the row's subtitle and a 🔒.
    let lockReason: String?

    /// Short hover tooltip for the locked row.
    ///
    /// Owned here rather than hard-coded in the view because the Auto Boot lock carries
    /// owner-specified Thai copy. `nil` means "fall back to `lockReason`". It is attached
    /// through `TooltipHost`, because SwiftUI's `.help(_:)` is macOS 11+ and this app's
    /// floor is 10.15.
    let tooltip: String?

    static let available = FeatureAvailability(isEnabled: true, lockReason: nil, tooltip: nil)

    static func locked(_ reason: String, tooltip: String? = nil) -> FeatureAvailability {
        FeatureAvailability(isEnabled: false, lockReason: reason, tooltip: tooltip)
    }
}

extension FeatureID {

    /// The warning shown in **every** Clear System Cache confirmation — the panel sheet,
    /// the status-item menu and the URL-scheme confirmation.
    ///
    /// One constant for all three so they can never drift: `rm -rf /Library/Caches/*` is
    /// the highest-risk action in the app, and the consequence has to be stated before the
    /// macOS password prompt appears. Thai first (owner-mandated copy), English second.
    static let clearSystemCacheWarning =
        "⚠️ การล้าง System Cache อาจทำให้บางแอปช้าลงชั่วคราว\n"
        + "Everything inside /Library/Caches will be deleted. Open applications may misbehave "
        + "and need to be restarted, and there is no way to undo this."

    /// One-line explanation shown under the row title.
    var detail: String {
        switch self {
        case .runAtStartup:     return "ON switches to menu-bar gadget mode and starts it at every login."
        case .gatekeeper:       return "ON means Gatekeeper is bypassed (macOS 15+ confirms in System Settings)."
        case .hiddenFiles:      return "ON means dotfiles are visible in Finder. Restarts Finder."
        case .autoBoot:         return "Power on automatically when power is restored."
        case .rosetta2:         return "Install Apple’s translation layer for Intel-only software."
        case .spotlightRebuild: return "Erase and rebuild the Spotlight index for /."
        case .dnsFlush:         return "Clear the DNS cache and restart mDNSResponder."
        case .clearSystemCache: return "Delete the contents of /Library/Caches. Destructive."
        }
    }

    /// True when the *write* path goes through `osascript … with administrator privileges`.
    /// State **reads are unprivileged in every case**, so opening the window costs nothing.
    var requiresElevation: Bool {
        switch self {
        case .runAtStartup, .gatekeeper, .autoBoot, .rosetta2,
             .spotlightRebuild, .dnsFlush, .clearSystemCache:
            return true
        case .hiddenFiles:
            return false
        }
    }

    /// Drives the CPU-gated rows from the cached `uname -m` result.
    ///
    /// Fail-safe: an unrecognised architecture locks both CPU-gated rows rather than
    /// guessing, because a wrongly-enabled `nvram` write is far worse than a greyed row.
    func availability(on architecture: CPUArchitecture) -> FeatureAvailability {
        switch self {
        case .autoBoot:
            guard architecture.supportsAutoBoot else {
                // Locked on Apple Silicon: M-series firmware owns `AutoBoot` and NVRAM is
                // wiped on every cold boot, so the setting cannot be changed by the user.
                // The tooltip is Thai by owner decision — `.disabled(true)` alone does not
                // tell anyone *why* a row is dead.
                return .locked("Auto Boot uses the firmware AutoBoot NVRAM variable, which does not exist on Apple Silicon.",
                               tooltip: "Apple Silicon ไม่รองรับ")
            }
            return .available
        case .rosetta2:
            guard architecture.supportsRosettaInstall else {
                return .locked("Rosetta 2 runs on Apple Silicon only — this Mac is Intel.")
            }
            return .available
        default:
            return .available
        }
    }
}
