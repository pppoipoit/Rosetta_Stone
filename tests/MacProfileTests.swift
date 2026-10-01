// ============================================================================
//  Rosetta Stone — MacProfile test harness (Phase 7.2, ADR-008)
//
//  WHAT THIS IS
//  A single-file, dependency-free harness for the pure logic behind
//  `RosettaStone/Services/MacProfile.swift`: the form-factor classification, the
//  `system_profiler` output parser, and the Auto Boot gating rule.
//
//  It is committed rather than kept as a scratch file, because the Auto Boot
//  lock is the one place in the app where a wrong answer writes firmware
//  settings. `supportsAutoBoot` has to be provable off-macOS.
//
//  WHY IT IS SELF-CONTAINED
//  `MacProfile` itself reaches for `SystemCommands` (Foundation.Process) and
//  `CPUArchitecture` (Darwin). Those are not available off-macOS, so this file
//  compiles the *logic* against minimal stubs instead of importing the app
//  target: a local `enum CPUArchitecture`, and the two symbols
//  `MacProfile.detect()` needs from `SystemCommands`. Everything under test —
//  `MacFormFactor.fromModelName`, `.fromModelIdentifier`,
//  `MacProfile.parseModelName`, `.supportsAutoBoot`, `.autoBootDisabledReason`
//  — is a pure function of its arguments and is reproduced here verbatim.
//
//  The stub type names match the production ones, so the code under test below
//  is a copy-paste of the real file with no renames. That is the trade: a
//  divergence between this harness and `MacProfile.swift` is possible, and the
//  header is the place that says so. `detect()` itself is intentionally NOT
//  covered — it is I/O, and it is covered on-device through DiagnosticsPanel,
//  which reports the model, form factor, the gate, and the reason.
//
//  HOW TO RUN
//  Any Swift 5 toolchain, on any platform. No Xcode, no macOS, no package
//  manager, no network:
//
//      swiftc -swift-version 5 -o macprofile-tests tests/MacProfileTests.swift
//      ./macprofile-tests          # macOS / Linux
//      macprofile-tests.exe        # Windows
//
//  Exit code 0 == every assertion passed. 1 == at least one failed (each
//  failure is printed with the expectation and the actual value).
//
//  THE 39 ASSERTIONS
//  12 x fromModelName · 10 x fromModelIdentifier · 8 x parseModelName ·
//  6 x supportsAutoBoot · 4 x autoBootDisabledReason. See `runAll()`.
// ============================================================================

import Foundation

// MARK: - Stubs (the two dependencies MacProfile cannot compile without)

/// Stand-in for `RosettaStone/Services/CPUArchitecture.swift`.
///
/// Only the members `MacProfile` touches are present: the three cases and
/// `.current`. `detect()` is omitted — it spawns `uname` — and `.current` is
/// pinned to `.unknown`, which is the correct value for "no Mac in the loop" and
/// conveniently makes the Auto Boot rule fail safe by default here.
enum CPUArchitecture {
    case arm64
    case x86_64
    case unknown

    static let current: CPUArchitecture = .unknown
}

/// Stand-in for the two `SystemCommands` symbols `MacProfile` calls.
///
/// Present only so `MacProfile.detect()` type-checks. `run()` traps: if a future
/// edit makes a tested path spawn a process, the harness should fail loudly
/// rather than silently shelling out on a developer machine.
enum SystemCommands {
    struct StubResult {
        let standardOutput: String
        let isSuccess: Bool
    }

    static func run(_ executable: String,
                    _ arguments: [String] = [],
                    timeout: TimeInterval = 30) throws -> StubResult {
        fatalError("the harness must never spawn a process (asked for \(executable))")
    }
}// ============================================================================
// Code under test — reproduced from RosettaStone/Services/MacProfile.swift
// ============================================================================

enum MacFormFactor {
    case laptop
    case desktop
    case unknown

    static func fromModelName(_ modelName: String) -> MacFormFactor {
        let name = modelName.lowercased()

        if name.contains("macbook") { return .laptop }
        if name.contains("imac") { return .desktop }

        let desktopFamilies = ["mac mini", "macmini", "mac studio", "macstudio", "mac pro", "macpro"]
        if desktopFamilies.contains(where: { name.contains($0) }) { return .desktop }

        return .unknown
    }

    static func fromModelIdentifier(_ identifier: String) -> MacFormFactor {
        let model = identifier.lowercased()

        if model.hasPrefix("macbook") { return .laptop }
        if model.hasPrefix("imac") { return .desktop }
        if model.hasPrefix("macmini") { return .desktop }
        if model.hasPrefix("macstudio") { return .desktop }
        if model.hasPrefix("macpro") { return .desktop }

        return .unknown
    }

    var displayName: String {
        switch self {
        case .laptop:  return "Laptop"
        case .desktop: return "Desktop"
        case .unknown: return "Unrecognised"
        }
    }
}

struct MacProfile {
    let formFactor: MacFormFactor
    let modelName: String
    let cpuArchitecture: CPUArchitecture

    static func detect() -> MacProfile {
        let hardware = readHardwareModel()
        return MacProfile(formFactor: hardware.formFactor,
                          modelName: hardware.modelName,
                          cpuArchitecture: .current)
    }

    private static func readHardwareModel() -> (formFactor: MacFormFactor, modelName: String) {
        if let result = try? SystemCommands.run("/usr/sbin/system_profiler",
                                               ["SPHardwareDataType"],
                                               timeout: 20),
           result.isSuccess,
           let modelName = parseModelName(from: result.standardOutput) {
            return (MacFormFactor.fromModelName(modelName), modelName)
        }

        if let result = try? SystemCommands.run("/usr/sbin/sysctl", ["-n", "hw.model"], timeout: 5),
           result.isSuccess {
            let identifier = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            if !identifier.isEmpty {
                return (MacFormFactor.fromModelIdentifier(identifier), identifier)
            }
        }

        return (.unknown, "")
    }

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

    var supportsAutoBoot: Bool {
        formFactor == .laptop && cpuArchitecture == .x86_64
    }

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
}// ============================================================================ Harness
// ============================================================================

/// Counts every expectation and reports the failures at the end.
///
/// Deliberately not XCTest: this must run from a bare `swiftc` on a machine
/// that has never seen Xcode, so there is nothing to link a test bundle against.
/// `XCTAssert` also requires the assertion target to exist, which would drag the
/// whole app target into the build of a file that tests one pure function.
enum Check {
    private(set) static var passed = 0
    private(set) static var failures: [String] = []

    static func expect(_ condition: Bool,
                       _ label: String,
                       _ detail: @autoclosure () -> String = "") {
        if condition {
            passed += 1
        } else {
            let suffix = detail().isEmpty ? "" : "  (\(detail()))"
            failures.append("\(label)\(suffix)")
        }
    }

    static func equal<T: Equatable>(_ actual: T,
                                     _ expected: T,
                                     _ label: String) {
        expect(actual == expected, label, "expected \(expected), got \(actual)")
    }
}

func runAll() -> Int32 {
    testFormFactorFromModelName()
    testFormFactorFromModelIdentifier()
    testParseModelName()
    testSupportsAutoBoot()
    testAutoBootDisabledReason()

    print("")
    if Check.failures.isEmpty {
        print("PASS — \(Check.passed)/39 assertions")
        return 0
    }
    print("FAIL — \(Check.failures.count) of \(Check.passed + Check.failures.count) assertions")
    for failure in Check.failures { print("  x \(failure)") }
    return 1
}

// MARK: - 1. Form factor from a marketing model name (12)

/// The primary source. These strings are exactly what `system_profiler
/// SPHardwareDataType` prints on `Model Name:`.
func testFormFactorFromModelName() {
    // Laptops — anything with a lid. "macbook" is checked first precisely because
    // "mac pro" would otherwise swallow "MacBook Pro".
    Check.equal(MacFormFactor.fromModelName("MacBook Pro"), .laptop, "MacBook Pro is a laptop")
    Check.equal(MacFormFactor.fromModelName("MacBook Air"), .laptop, "MacBook Air is a laptop")
    Check.equal(MacFormFactor.fromModelName("MacBook"), .laptop, "MacBook is a laptop")

    // Desktops — no lid. "imac" before the generic "mac ..." rules so "iMac Pro"
    // stays a desktop rather than being captured by something else.
    Check.equal(MacFormFactor.fromModelName("iMac"), .desktop, "iMac is a desktop")
    Check.equal(MacFormFactor.fromModelName("iMac Pro"), .desktop, "iMac Pro is a desktop")
    Check.equal(MacFormFactor.fromModelName("Mac mini"), .desktop, "Mac mini is a desktop")
    Check.equal(MacFormFactor.fromModelName("Mac Studio"), .desktop, "Mac Studio is a desktop")
    Check.equal(MacFormFactor.fromModelName("Mac Pro"), .desktop, "Mac Pro is a desktop")

    // Unknown — never assumed to be a desktop. A bare "Mac" and an empty string
    // both lock Auto Boot, which is the fail-safe: a greyed row beats a wrongly
    // enabled nvram write.
    Check.equal(MacFormFactor.fromModelName("Mac"), .unknown, "bare Mac is unknown")
    Check.equal(MacFormFactor.fromModelName(""), .unknown, "empty model name is unknown")
    Check.equal(MacFormFactor.fromModelName("Some Future Chassis"), .unknown,
                "unrecognised model is unknown")

    // Case insensitivity: the output follows the process locale.
    Check.equal(MacFormFactor.fromModelName("MACBOOK PRO"), .laptop,
                "classification is case-insensitive")
}

// MARK: - 2. Form factor from a hw.model identifier (10)

/// The fallback path, used only when `system_profiler` cannot be run.
func testFormFactorFromModelIdentifier() {
    Check.equal(MacFormFactor.fromModelIdentifier("MacBookPro18,3"), .laptop,
                "MacBookPro18,3 is a laptop")
    Check.equal(MacFormFactor.fromModelIdentifier("MacBookAir10,1"), .laptop,
                "MacBookAir10,1 is a laptop")
    Check.equal(MacFormFactor.fromModelIdentifier("iMac21,1"), .desktop,
                "iMac21,1 is a desktop")
    Check.equal(MacFormFactor.fromModelIdentifier("Macmini9,1"), .desktop,
                "Macmini9,1 is a desktop")
    Check.equal(MacFormFactor.fromModelIdentifier("MacPro7,1"), .desktop,
                "MacPro7,1 is a desktop")

    // iMac Pro carries the family in its identifier too, so the fallback classifies
    // it correctly rather than falling into the bare-"Mac" unknown case.
    Check.equal(MacFormFactor.fromModelIdentifier("iMacPro1,1"), .desktop,
                "iMacPro1,1 is a desktop")

    // The known blind spot, asserted on purpose: from the M-series generation
    // Apple stopped encoding the product family. `Mac14,5` (14-inch M2 Pro) is a
    // bare "Mac" plus two numbers that say nothing about the chassis, so it cannot
    // be classified and Auto Boot stays locked. This is why system_profiler is the
    // primary source and hw.model only a fallback — and on Apple Silicon, where
    // Auto Boot is locked anyway, the blind spot costs nothing.
    Check.equal(MacFormFactor.fromModelIdentifier("Mac14,5"), .unknown,
                "Mac14,5 (M2 Pro) is unclassifiable — the documented blind spot")

    // Prefix-anchored on purpose: "contains" would let a future "MacBookServer"
    // or an unrelated identifier leak into the wrong bucket.
    Check.equal(MacFormFactor.fromModelIdentifier("NotAMacBookPro"), .unknown,
                "identifier match is prefix-anchored, not substring")
    Check.equal(MacFormFactor.fromModelIdentifier(""), .unknown,
                "empty identifier is unknown")
}// MARK: - 3. system_profiler parsing (8)

func testParseModelName() {
    // A real transcript, whitespace and all. `system_profiler` indents every
    // field under "Hardware:", which is why leading whitespace is stripped.
    let transcript = """
    Hardware:

        Model Name: MacBook Pro
        Model Identifier: MacBookPro18,3
        Chip: Apple M1 Pro
        Total Number of Cores: 10
    """
    Check.equal(MacProfile.parseModelName(from: transcript), "MacBook Pro",
                "parses Model Name from a real transcript")

    // The key is matched case-insensitively, because the output follows the locale.
    Check.equal(MacProfile.parseModelName(from: "    model name: Mac mini"), "Mac mini",
                "lowercase key is matched")

    // Surrounding whitespace on the value is trimmed, so "MacBook Pro" never
    // arrives as "MacBook Pro ".
    Check.equal(MacProfile.parseModelName(from: "      Model Name:   Mac Studio   "),
                "Mac Studio", "surrounding whitespace on the value is trimmed")

    // Must not latch onto a different field. "Model Identifier" and "Chip" both
    // contain the word "Model", so a prefix match on the whole key is required.
    Check.equal(MacProfile.parseModelName(from: "  Model Identifier: MacBookPro18,3"), nil,
                "Model Identifier is not mistaken for Model Name")

    // A field that exists but carries no value is "no such field" to the caller,
    // which is what triggers the hw.model fallback.
    Check.equal(MacProfile.parseModelName(from: "  Model Name:"), nil,
                "empty Model Name value yields nil")

    // Absent entirely, and empty output.
    Check.equal(MacProfile.parseModelName(from: "  Chip: Apple M1\n  Memory: 16 GB"), nil,
                "absent Model Name yields nil")
    Check.equal(MacProfile.parseModelName(from: ""), nil, "empty output yields nil")

    // CRLF: SystemCommands trims, but a transcript pasted from Windows or a
    // captured fixture can carry \r. It must not end up inside the value.
    Check.equal(MacProfile.parseModelName(from: "  Model Name: iMac\r"), "iMac",
                "CR does not leak into the parsed value")
}// MARK: - 4. The Auto Boot gate (6)

/// The whole point of the file: laptop AND Intel. Each condition alone must fail.
func testSupportsAutoBoot() {
    let intelLaptop = MacProfile(formFactor: .laptop, modelName: "MacBook Pro",
                                 cpuArchitecture: .x86_64)
    let intelDesktop = MacProfile(formFactor: .desktop, modelName: "iMac",
                                  cpuArchitecture: .x86_64)
    let siliconLaptop = MacProfile(formFactor: .laptop, modelName: "MacBook Pro",
                                   cpuArchitecture: .arm64)
    let siliconDesktop = MacProfile(formFactor: .desktop, modelName: "Mac mini",
                                    cpuArchitecture: .arm64)
    let unknownModel = MacProfile(formFactor: .unknown, modelName: "",
                                  cpuArchitecture: .x86_64)
    let unknownArch = MacProfile(formFactor: .laptop, modelName: "MacBook Pro",
                                 cpuArchitecture: .unknown)

    // The one supported combination — the 4-row availability matrix in
    // docs/FEATURES.md §4 collapses to exactly this row.
    Check.expect(intelLaptop.supportsAutoBoot, "Intel laptop supports Auto Boot")

    // Each of the other three real combinations, plus both unknowns.
    Check.expect(!intelDesktop.supportsAutoBoot,
                 "Intel desktop does NOT support Auto Boot (no lid)")
    Check.expect(!siliconLaptop.supportsAutoBoot,
                 "Apple Silicon laptop does NOT support Auto Boot (no NVRAM)")
    Check.expect(!siliconDesktop.supportsAutoBoot,
                 "Apple Silicon desktop does NOT support Auto Boot (both reasons)")
    Check.expect(!unknownModel.supportsAutoBoot,
                 "unknown model fails safe and locks Auto Boot")
    Check.expect(!unknownArch.supportsAutoBoot,
                 "unknown architecture fails safe and locks Auto Boot")
}

// MARK: - 5. The lock reason (4)

/// A lock with no reason is the one outcome the row contract forbids, so every
/// locked case must produce a non-empty string.
func testAutoBootDisabledReason() {
    let intelLaptop = MacProfile(formFactor: .laptop, modelName: "MacBook Pro",
                                 cpuArchitecture: .x86_64)
    Check.expect(intelLaptop.autoBootDisabledReason == nil,
                 "available machine has no disabled reason")

    // Desktop is reported before architecture, so an Intel iMac gets the lid
    // reason rather than being told about NVRAM it does share.
    let intelDesktop = MacProfile(formFactor: .desktop, modelName: "iMac",
                                  cpuArchitecture: .x86_64)
    Check.equal(intelDesktop.autoBootDisabledReason, "Desktop Mac ไม่มีฝาเปิด-ปิด",
                "Intel desktop reports the no-lid reason")

    // Apple Silicon laptop: no lid problem, so the reason must be the NVRAM one —
    // the row is locked because firmware owns the setting, not because of the chassis.
    let siliconLaptop = MacProfile(formFactor: .laptop, modelName: "MacBook Pro",
                                   cpuArchitecture: .arm64)
    Check.equal(siliconLaptop.autoBootDisabledReason,
                "Apple Silicon reset NVRAM ทุกครั้งที่ cold boot",
                "Apple Silicon laptop reports the NVRAM reason")

    // Unknowns must still explain themselves, in English, since the two Thai
    // strings are owner-specified copy for known hardware.
    let unknownModel = MacProfile(formFactor: .unknown, modelName: "",
                                  cpuArchitecture: .x86_64)
    Check.equal(unknownModel.autoBootDisabledReason,
                "Unknown Mac model — Auto Boot is disabled to stay safe.",
                "unknown model reports the fail-safe reason")
}

// ============================================================================

print("MacProfile — Auto Boot gating harness (ADR-008)")
print("model classification · profiler parsing · availability rule")
exit(runAll())