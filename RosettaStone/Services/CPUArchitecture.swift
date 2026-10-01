import Foundation

/// Host CPU architecture, detected once at launch with `uname -m` (ADR-007).
///
/// Rejected alternatives, for the record:
/// - `sysctlbyname("hw.optional.arm64")` — macOS 11.0+, unusable on the 10.15 floor.
///   (It is still used here as a *fallback* via the `sysctl` binary, which is 10.0+.)
/// - `ProcessInfo.isTranslated` — reports whether *this process* is translated, not
///   what the host CPU is.
/// - `#if arch(arm64)` — compile time; a single binary must branch on the host at runtime.
enum CPUArchitecture: String {

    /// Apple Silicon.
    case arm64

    /// Intel.
    case x86_64

    /// Anything else — a future architecture, or `uname` could not be run.
    /// Locks both CPU-gated rows rather than guessing.
    case unknown

    /// Cached for the process lifetime: the host architecture cannot change while the
    /// app is running, so there is no reason to spawn a process during rendering.
    static let current: CPUArchitecture = detect()

    /// Runs `/usr/bin/uname -m` and falls back to `sysctl -n hw.optional.arm64`.
    static func detect() -> CPUArchitecture {
        if let result = try? SystemCommands.run("/usr/bin/uname", ["-m"], timeout: 5), result.isSuccess {
            switch result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "arm64":
                return .arm64
            case "x86_64":
                return .x86_64
            default:
                break // fall through to the sysctl probe
            }
        }

        // `hw.optional.arm64` exists only on Apple Silicon and prints 1 there.
        if let result = try? SystemCommands.run("/usr/sbin/sysctl", ["-n", "hw.optional.arm64"], timeout: 5),
           result.isSuccess,
           result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) == "1" {
            return .arm64
        }

        return .unknown
    }

    // MARK: - Availability

    /// Rosetta 2 is an Apple Silicon feature. Note this is used to gate the *UI only* —
    /// whether Rosetta is *installed* is decided by probing
    /// `/usr/libexec/oah/libRosettaRuntime`, because an Apple Silicon Mac running this
    /// binary under Rosetta would still report `x86_64` from `uname -m`.
    ///
    /// ## Auto Boot is deliberately **not** answered here
    ///
    /// An earlier revision answered "does this Mac support Auto Boot?" from the
    /// architecture alone (`self == .x86_64`), which let every Intel desktop through — an
    /// iMac, Mac mini, Mac Studio or Mac Pro all pass `uname -m`, none of them has a lid,
    /// and on Intel desktop firmware `nvram AutoBoot` is absent or inert. That question
    /// needs the model as well as the chip, so the single source of truth is now
    /// `MacProfile.supportsAutoBoot`, which requires **both** `formFactor == .laptop`
    /// **and** `cpuArchitecture == .x86_64`. `FeatureID.availability(on:)` asks the profile,
    /// never this type, so there is exactly one Auto Boot rule in the codebase.
    var supportsRosettaInstall: Bool { self == .arm64 }

    /// Human-readable label for the menu-bar menu and the window subtitle.
    var displayName: String {
        switch self {
        case .arm64:  return "Apple Silicon"
        case .x86_64: return "Intel"
        case .unknown: return "Unrecognised"
        }
    }

    /// True when this process is translated by Rosetta 2. Informational only — it is
    /// deliberately **not** used for availability decisions.
    var isRunningUnderTranslation: Bool {
        guard #available(macOS 10.15, *) else { return false }
        var translated: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let result = sysctlbyname("sysctl.proc_translated", &translated, &size, nil, 0)
        return result == 0 && translated == 1
    }
}
