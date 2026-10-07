import Foundation

/// The eight capabilities defined in `docs/FEATURES.md`, in their fixed row order.
///
/// `rawValue` doubles as the **batch marker** each row writes to stdout inside the
/// elevated batch script (`toggle-gatekeeper`, `install-rosetta`, …), so the parser can
/// only ever match a result to the row that produced it — exact match, never a prefix.
enum FeatureID: String, CaseIterable {
    case runAtStartup       = "run-at-startup"
    case gatekeeper         = "toggle-gatekeeper"
    case hiddenFiles        = "toggle-hidden-files"
    case autoBoot           = "auto-boot"
    case rosetta2           = "install-rosetta"
    case spotlightRebuild   = "rebuild-spotlight"
    case dnsFlush           = "flush-dns"
    case clearSystemCache   = "clear-cache"

    /// **Display name** for the row — the human label of the toggle or button.
    ///
    /// The single source of truth for the name a user reads. Every surface that has to
    /// name a feature reads it from here — the main panel, the mini menu-bar panel, the
    /// batch results dialog, the diagnostics report and the menu items — so a row cannot
    /// be called one thing in the panel and another in a dialog.
    ///
    /// `title` is kept as a deprecated-style alias because it reads better at the call
    /// sites that are naming a *row* rather than a *feature*; both resolve to this value,
    /// so the two tables cannot drift.
    var displayName: String {
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

    /// Row label as shown in the panel. Alias of `displayName`.
    var title: String { displayName }
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

    /// The warning shown in **every** Clear System Cache confirmation — the panel sheet
    /// and the status-item menu.
    ///
    /// One constant for all three so they can never drift: `rm -rf /Library/Caches/*` is
    /// the highest-risk action in the app, and the consequence has to be stated before the
    /// macOS password prompt appears. Thai first (owner-mandated copy), English second.
    static let clearSystemCacheWarning =
        "⚠️ การล้าง System Cache อาจทำให้บางแอปช้าลงชั่วคราว\n"
        + "Everything inside /Library/Caches will be deleted. Open applications may misbehave "
        + "and need to be restarted, and there is no way to undo this."

    /// One-line explanation shown under the row title.
    ///
    /// **Every toggle carries one.** A switch with no explanation makes the user guess what
    /// ON actually does — and on the row where guessing wrong means lowering a security
    /// setting (Gatekeeper) or diverging from the system default (Hidden Files) the guess
    /// is expensive. `description` is the canonical name; `detail`
    /// is a retained alias so existing call sites keep working against the same table.
    var description: String {
        switch self {
        case .runAtStartup:     return "ON switches to menu-bar gadget mode and starts it at every login."
        case .gatekeeper:       return "ON means macOS enforces Gatekeeper; OFF lets any app run (macOS 15+ confirms the OFF direction in System Settings)."
        case .hiddenFiles:      return "ON means dotfiles are visible in Finder. Updates open windows."
        case .autoBoot:         return "Power on automatically when power is restored."
        case .rosetta2:         return "Install Apple’s translation layer for Intel-only software."
        case .spotlightRebuild: return "Erase and rebuild the Spotlight index for /."
        case .dnsFlush:         return "Clear the DNS cache and restart mDNSResponder."
        case .clearSystemCache: return "Delete the contents of /Library/Caches. Destructive."
        }
    }

    /// Retained alias of `description`.
    var detail: String { description }

    /// The order the **panel** draws its rows in (owner-specified, Phase 11).
    ///
    /// Deliberately separate from `FeatureID.allCases`, which is the batch-commit order
    /// (the order the deferred batch is committed in). The two orders answer different
    /// questions — "what the user sees" versus "what the batch commits first" — and pinning
    /// the display order to the commit order would make a cosmetic change a behaviour change.
    ///
    /// The order itself: Gatekeeper and Hidden Files first (the two people reach for
    /// constantly), then the two posture rows, then Rosetta, then Quick Tools.
    static let panelRowOrder: [FeatureID] = [
        .gatekeeper,        // 1 — most-used security switch
        .autoBoot,          // 2 — power behaviour
        .hiddenFiles,       // 3 — Finder visibility
        .runAtStartup,      // 4 — the posture switch itself, deliberately below the rows it changes
        .rosetta2,          // 5 — one-shot install
        .spotlightRebuild,  // 6 — Quick Tools
        .dnsFlush,
        .clearSystemCache
    ]

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

    /// Drives the hardware-gated rows from the cached profile (ADR-007 + ADR-008).
    ///
    /// Takes the whole `MacProfile` rather than a bare `CPUArchitecture` because Auto Boot
    /// needs **both** answers — Intel **and** a lid — and passing only the architecture is
    /// what let Intel desktops through in the first place.
    ///
    /// Fail-safe: an unrecognised architecture *or* model locks the Auto Boot row rather
    /// than guessing, because a wrongly-enabled `nvram` write is far worse than a greyed row.
    func availability(on profile: MacProfile) -> FeatureAvailability {
        switch self {
        case .autoBoot:
            guard profile.supportsAutoBoot else {
                // Locked on Apple Silicon (M-series firmware owns `AutoBoot` and NVRAM is
                // wiped on every cold boot) and on desktops (no lid to open, and on Intel
                // firmware `nvram AutoBoot` is absent or inert).
                //
                // The reason string is Thai by owner decision — `.disabled(true)` alone does
                // not tell anyone *why* a row is dead — and it is used for **both** the
                // subtitle and the tooltip, so the greyed row explains itself inline and on
                // hover. A lock with no reason is the one outcome this row contract forbids.
                let reason = profile.autoBootDisabledReason
                    ?? "Auto Boot is unavailable on this Mac."
                return .locked(reason, tooltip: reason)
            }
            return .available
        case .rosetta2:
            // Still purely architectural: Rosetta 2 does not care whether there is a lid.
            guard profile.cpuArchitecture.supportsRosettaInstall else {
                return .locked("Rosetta 2 runs on Apple Silicon only — this Mac is Intel.")
            }
            return .available
        default:
            return .available
        }
    }
}
