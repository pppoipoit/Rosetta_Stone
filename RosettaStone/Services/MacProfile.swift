import Foundation

/// The physical shape of the Mac — laptop or desktop.
///
/// ## Why the app cares
///
/// Feature 4 (Auto Boot) writes the firmware `AutoBoot` NVRAM variable, which is meaningful
/// on Intel **laptops** only. The architecture check that has always gated the row is not
/// sufficient on its own: an Intel **iMac / Mac mini / Mac Studio / Mac Pro** passes the
/// `uname -m` test, so the row is offered, and a user who toggles it either changes a
/// setting that does nothing or gets an `nvram` write that fails. Those machines have no
/// lid to open in the first place, which is exactly what the setting is about
/// (`docs/FEATURES.md` §4).
///
/// `.unknown` is a **first-class** answer, not an error case: `system_profiler` can be slow,
/// blocked by policy, or absent from a trimmed system image. Following the fail-safe rule
/// already used for `CPUArchitecture.unknown`, an unrecognised model **locks** the Auto Boot
/// row rather than guessing, because a wrongly-enabled `nvram` write is far worse than a
/// greyed-out row.
enum MacFormFactor {

    /// MacBook Air, MacBook Pro, MacBook — anything with a lid.
    case laptop

    /// iMac, Mac mini, Mac Studio, Mac Pro — no lid.
    case desktop

    /// The model could not be read, or is one this app does not recognise.
    case unknown

    // MARK: - Classification

    /// Classifies a **marketing model name** — the `Model Name` value printed by
    /// `system_profiler SPHardwareDataType`, e.g. `MacBook Pro`, `iMac`, `Mac mini`,
    /// `Mac Studio`, `Mac Pro`, `Mac`.
    ///
    /// Deliberately a pure function of its argument, so the rule is verifiable against
    /// real `system_profiler` transcripts without a Mac in the loop.
    ///
    /// The order of the checks is load-bearing:
    /// - **"macbook" first**, because `MacBook Pro` must not be captured by the `mac pro`
    ///   desktop rule below,
    /// - **`"imac"` before the generic `mac …` rules**, so `iMac Pro` stays a desktop,
    /// - **the `mac mini` / `mac studio` / `mac pro` rules before giving up**, because
    ///   every desktop begins with the bare word `Mac` and would otherwise look unknown.
    static func fromModelName(_ modelName: String) -> MacFormFactor {
        let name = modelName.lowercased()

        if name.contains("macbook") { return .laptop }
        if name.contains("imac") { return .desktop }

        let desktopFamilies = ["mac mini", "macmini", "mac studio", "macstudio", "mac pro", "macpro"]
        if desktopFamilies.contains(where: { name.contains($0) }) { return .desktop }

        // A bare `Mac`, an empty string, or anything else unrecognised. Deliberately
        // **not** assumed to be a desktop: guessing would wrongly unlock Auto Boot on a
        // future form factor that happens to have a lid.
        return .unknown
    }

    /// Classifies a **machine identifier** — the `hw.model` value (`MacBookPro18,3`,
    /// `iMac21,1`, `Macmini9,1`, `MacPro7,1`, `Mac14,5`) — used only as a fallback when
    /// `system_profiler` cannot be run.
    ///
    /// ## The known blind spot
    ///
    /// From the M-series generation Apple stopped encoding the product family:
    /// `hw.model` for an M1 MacBook Pro is `MacBookPro18,3`, but for a 14-inch M2 Pro it is
    /// `Mac14,5` — a bare `Mac` plus two numbers that say nothing about the chassis. That
    /// string cannot be classified, so it yields `.unknown` and Auto Boot stays locked.
    /// That is the intended fail-safe, and it is the reason `system_profiler` is the primary
    /// source and `hw.model` only a fallback.
    static func fromModelIdentifier(_ identifier: String) -> MacFormFactor {
        let model = identifier.lowercased()

        if model.hasPrefix("macbook") { return .laptop }
        if model.hasPrefix("imac") { return .desktop }
        if model.hasPrefix("macmini") { return .desktop }
        if model.hasPrefix("macstudio") { return .desktop }
        if model.hasPrefix("macpro") { return .desktop }

        return .unknown
    }

    // MARK: - Presentation

    /// Label for the diagnostics report and the window subtitle.
    var displayName: String {
        switch self {
        case .laptop:  return "Laptop"
        case .desktop: return "Desktop"
        case .unknown: return "Unrecognised"
        }
    }
}

/// What this Mac **is**, as opposed to what its CPU is: the model name read from
/// `system_profiler`, the form factor derived from it, and the already-detected
/// `CPUArchitecture`.
///
/// Complements `CPUArchitecture` rather than replacing it — the two answer different
/// questions and the Auto Boot row needs both:
///
/// | Type | Question | Source |
/// |------|----------|--------|
/// | `CPUArchitecture` | Intel or Apple Silicon? | `uname -m` (ADR-007) |
/// | `MacProfile` | Does this machine have a lid? | `system_profiler SPHardwareDataType` |
///
/// ## Unprivileged and unprompted
///
/// Like every other reader in the app (`SystemStateReader`), detection only **reads**: no
/// `nvram` write, no `osascript`, therefore **no password prompt** — opening the window
/// still costs the user nothing (`docs/ARCHITECTURE.md` §4). It also does not shell out to
/// `grep`: `system_profiler` is executed directly through `SystemCommands.run` and its
/// output parsed in Swift, which keeps this a constants-only command with no shell in the
/// loop.
struct MacProfile {

    let formFactor: MacFormFactor

    /// The `Model Name` printed by `system_profiler` (e.g. `MacBook Pro`), falling back to
    /// the `hw.model` identifier when the profiler is unavailable. **Empty** when neither
    /// could be read — an unknown model is never invented.
    let modelName: String

    let cpuArchitecture: CPUArchitecture

    // MARK: - Detection

    /// Detected once per process: the hardware cannot change while the app is running, so
    /// there is no reason to spawn a process during rendering — the same reasoning as
    /// `CPUArchitecture.current`.
    static let current: MacProfile = detect()

    /// Reads the model name, classifies it, and pairs it with the cached architecture.
    static func detect() -> MacProfile {
        let hardware = readHardwareModel()
        return MacProfile(formFactor: hardware.formFactor,
                          modelName: hardware.modelName,
                          cpuArchitecture: .current)
    }

    /// Paths to the two read-only sources, both outside any user-writable tree.
    private enum Tool {
        static let systemProfiler = "/usr/sbin/system_profiler"
        static let sysctl = "/usr/sbin/sysctl"
    }

    /// `system_profiler` walks the whole hardware tree and can take several seconds on a
    /// cold cache, so it gets a far larger budget than the 5 seconds `uname -m` is given.
    /// A timeout here degrades to the `hw.model` fallback rather than failing outright.
    private static let detectionTimeout: TimeInterval = 20

    /// Reads the hardware identity, preferring the profiler and falling back to `sysctl`.
    ///
    /// Order matters: `system_profiler` reports the **marketing** model name, which is what
    /// carries the product family on every Apple Silicon machine; `hw.model` does not (see
    /// `fromModelIdentifier`). The fallback therefore only ever helps on Intel hardware.
    private static func readHardwareModel() -> (formFactor: MacFormFactor, modelName: String) {
        if let result = try? SystemCommands.run(Tool.systemProfiler,
                                               ["SPHardwareDataType"],
                                               timeout: detectionTimeout),
           result.isSuccess,
           let modelName = parseModelName(from: result.standardOutput) {
            return (MacFormFactor.fromModelName(modelName), modelName)
        }

        // `hw.model` is a single scalar, so it is quick — but it still needs a real
        // timeout, because `SystemCommands.run` throws rather than returning on a hang.
        if let result = try? SystemCommands.run(Tool.sysctl, ["-n", "hw.model"], timeout: 5),
           result.isSuccess {
            let identifier = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            if !identifier.isEmpty {
                return (MacFormFactor.fromModelIdentifier(identifier), identifier)
            }
        }

        return (.unknown, "")
    }

    /// Extracts the value of the `Model Name:` line from `system_profiler` output.
    ///
    /// Parsing in Swift rather than piping through `grep "Model Name"` for two reasons: a
    /// shell fragment would be the only one in an otherwise constants-only command set, and
    /// this parser can be exercised directly against captured transcripts on any platform.
    ///
    /// Leading whitespace is stripped because the profiler indents every field under
    /// `Hardware:`, and the comparison is case-insensitive because the output follows the
    /// process locale. `nil` means "no such field", which the caller treats as "try the
    /// fallback".
    static func parseModelName(from output: String) -> String? {
        let key = "model name:"
        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().hasPrefix(key) else { continue }
            let value = trimmed.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
            if !value.isEmpty { return value }
        }
        return nil
    }

    // MARK: - Feature 4 gating

    /// Whether the Auto Boot toggle is meaningful on this Mac.
    ///
    /// Both conditions are required and neither alone is sufficient:
    /// - **Apple Silicon** — M-series firmware owns `AutoBoot` and NVRAM is wiped on every
    ///   cold boot, so the setting cannot persist and there is nothing for the user to
    ///   change (`docs/FEATURES.md` §4).
    /// - **Desktop** — there is no lid. The behaviour the row controls ("power on
    ///   automatically when the lid is opened") does not exist on an iMac or a Mac mini, and
    ///   on Intel desktops `nvram AutoBoot` is absent or has no effect.
    ///
    /// An `.unknown` model therefore locks the row, matching the fail-safe rule already
    /// applied to an unrecognised `CPUArchitecture`.
    var supportsAutoBoot: Bool {
        formFactor == .laptop && cpuArchitecture == .x86_64
    }

    /// Why Auto Boot is unavailable, or `nil` when it is available.
    ///
    /// Thai by owner decision, like the existing Apple Silicon lock tooltip: a greyed row
    /// that cannot explain itself reads as a bug (`FeatureAvailability.tooltip`). The first
    /// two strings are owner-specified; the last two are this service's own addition for
    /// the cases the first two do not cover, because a lock with no reason is the one
    /// outcome this app's row contract forbids.
    var autoBootDisabledReason: String? {
        guard !supportsAutoBoot else { return nil }

        if formFactor == .desktop {
            return "Desktop Mac ไม่มีฝาเปิด-ปิด"
        }
        if cpuArchitecture == .arm64 {
            return "Apple Silicon reset NVRAM ทุกครั้งที่ cold boot"
        }

        if formFactor == .unknown {
            return "Unknown Mac model — Auto Boot is disabled to stay safe."
        }
        return "Unknown CPU architecture — Auto Boot is disabled to stay safe."
    }
}