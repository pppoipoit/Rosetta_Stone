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

    static let available = FeatureAvailability(isEnabled: true, lockReason: nil)

    static func locked(_ reason: String) -> FeatureAvailability {
        FeatureAvailability(isEnabled: false, lockReason: reason)
    }
}

extension FeatureID {

    /// One-line explanation shown under the row title.
    var detail: String {
        switch self {
        case .runAtStartup:     return "Launch the menu-bar icon automatically at every login."
        case .gatekeeper:       return "ON means Gatekeeper is bypassed (less secure)."
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
                return .locked("Auto Boot uses the firmware AutoBoot NVRAM variable, which does not exist on Apple Silicon.")
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
