# Architecture Decision Records

Every significant technical choice in Rosetta Stone, recorded with the alternatives that were
considered and the reason the chosen option won.

| ADR | Decision | Status |
|-----|----------|--------|
| [ADR-001](#adr-001) | Use `NSStatusItem` instead of SwiftUI `MenuBarExtra` | Accepted |
| [ADR-002](#adr-002) | Use a custom URL scheme instead of App Intents | Accepted |
| [ADR-003](#adr-003) | Distribute with ad-hoc code signing, no Developer ID | Accepted |
| [ADR-004](#adr-004) | Use `create-dmg` for macOS disk images | Accepted |
| [ADR-005](#adr-005) | Build per-architecture DMGs via a CI matrix | Accepted |
| [ADR-006](#adr-006) | Escalate privileges with `osascript … with administrator privileges` | Accepted |
| [ADR-007](#adr-007) | Detect CPU architecture with `uname -m` | Accepted |
| [ADR-008](#adr-008) | Gate Auto Boot on a full `MacProfile` (model + form factor + arch) | Accepted |

---

## ADR-001: `NSStatusItem` instead of SwiftUI `MenuBarExtra`

**Status:** Accepted · **Date:** 2026-09-29

### Context
Rosetta Stone must live in the menu bar. SwiftUI offers two approaches: the modern `MenuBarExtra`
container, or the older AppKit `NSStatusItem` managed by an `NSApplicationDelegate`. The project
must support **macOS 10.15 (Catalina)**.

### Decision
Use AppKit **`NSStatusItem`**, managed from `AppDelegate`, and drive the main window from SwiftUI as
usual.

### Rationale
`MenuBarExtra` was introduced in **macOS 13 (Ventura)**. Using it would make the 10.15 deployment
floor impossible — either by raising the minimum to 13, or by wrapping every call in
`if #available(macOS 13, *)` and shipping a completely different menu-bar implementation for the
older OS versions the project explicitly supports. `NSStatusItem` has been available since
**macOS 10.10** and behaves identically on 10.15 through 27.

### Consequences

**Positive**

| Benefit | Detail |
|---------|--------|
| Full 10.15 support | One code path serves every supported OS version. |
| Stable API | `NSStatusItem.button`, `.menu`, `.behavior` have not materially changed since 10.10. |
| Control | An `NSStatusItem` can host a custom `NSView`, giving complete control over the popover's appearance. |
| Predictable lifecycle | The status item is installed and torn down explicitly by `AppDelegate`, so ordering is deterministic. |

**Negative**

| Cost | Mitigation |
|------|------------|
| `MenuBarExtra`'s declarative SwiftUI syntax is lost — this is AppKit code in a SwiftUI app. | Confined to one file in `Views/MenuBar/`. The rest of the UI stays pure SwiftUI. |
| `MenuBarExtra` handles menu-style vs. window-style behaviour automatically. | Behaviour is set explicitly with `NSStatusItemBehavior`, and the panel is shown by calling `orderFront` on the `NSWindow`. |
| Requires an `AppDelegate` and manual wiring. | The `App` type uses `@NSApplicationDelegateAdaptor`; standard for any AppKit-interop macOS app. |

### Alternatives considered

| Alternative | Why rejected |
|-------------|--------------|
| SwiftUI `MenuBarExtra` | macOS 13+ only. Directly conflicts with the 10.15 support commitment. |
| A third-party menu-bar library | An external dependency for an API the OS already provides; such libraries also impose higher minimum OS versions. |

---

## ADR-002: Custom URL scheme instead of App Intents

**Status:** Accepted · **Date:** 2026-09-29

### Context
Rosetta Stone must be drivable from Apple Shortcuts, and the deployment floor is **macOS 10.15**.

### Decision
Register the custom URL scheme **`rosettastone://`** in `Info.plist` via `CFBundleURLTypes`, and
handle incoming URLs in `AppDelegate.application(_:open:)`.

### Rationale
**App Intents** requires **macOS 13+**. Shortcuts can only invoke app intents on older systems via a
compatibility shim, and the intents themselves are unavailable below Ventura. The custom URL scheme
has been supported since macOS 10.0, works on every supported version, and is callable from
Shortcuts, Alfred, Raycast, `open` in a shell script, and any automation framework that can open a
URL. It therefore delivers the *same user-facing capability* with a 13-version-wider reach.

### Consequences

**Positive**

| Benefit | Detail |
|---------|--------|
| Works on 10.15 → 27 | One integration surface for every supported OS. |
| Callable from anywhere | Shortcuts, Alfred, Raycast, `open`, `osascript`, a cron job. |
| No entitlement required | URL schemes need no entitlement and no associated-domains file. |
| No dependency | Pure `CFBundleURLTypes` + `NSApplicationDelegate`. |

**Negative**

| Cost | Mitigation |
|------|------------|
| Users must type or pick a URL rather than seeing a named intent in Shortcuts. | Documented in [USER-GUIDE.md §9](USER-GUIDE.md#9-apple-shortcuts) with ready-made URL lists. |
| No typed parameters — everything is a string. | The action set is deliberately small and parameterless. Query strings are accepted and ignored rather than honoured, so an injected parameter cannot escalate a harmless call into a dangerous one. |
| Untyped input can arrive from any app on the system. | Every URL is validated against a fixed allow-list. Unknown actions are logged and discarded — never executed. Destructive actions keep their confirmation dialog even when URL-driven. |
| No automatic discoverability in Spotlight/Siri. | Accepted; the app has no Dock icon or Spotlight metadata anyway. |

### Alternatives considered

| Alternative | Why rejected |
|-------------|--------------|
| App Intents / `AppShortcutsProvider` | macOS 13+ only. Breaks the 10.15 floor. |
| AppleScript scripting dictionary (`NSAppleScript` + `.scriptTerminology`) | Requires a bundled `OSAScriptingDefinition` resource and a signed bundle; far more machinery for no gain on modern macOS, where Shortcuts' **Run Script** action covers scripting needs. |
| A local socket / XPC service | Heavier IPC with its own lifecycle and permission model, and invisible to Shortcuts. |

---

## ADR-003: Ad-hoc code signing, no Developer ID

**Status:** Accepted · **Date:** 2026-09-29

### Context
Rosetta Stone is distributed as a free DMG. Apple Developer Program membership costs **US$99/year**.
Notarization additionally requires a Developer ID Application certificate and an app-specific
password or App Store Connect API key.

### Decision
Sign the built bundle **ad-hoc** in CI:

```bash
codesign --force --deep --sign - --timestamp=none build/RosettaStone.app
```

Do **not** notarize, staple, or use a Developer ID certificate.

### Rationale
Ad-hoc signing requires no certificate, no secret in the repository, and no Apple account. The build
is fully reproducible from a clean clone with zero configuration. The cost is real and is accepted
deliberately: **the first launch shows a Gatekeeper warning**, and users must right-click →
**Open** once. This is documented prominently in [USER-GUIDE.md §4](USER-GUIDE.md#first-launch) and
in the README security disclaimer.

### Consequences

**Positive**

| Benefit | Detail |
|---------|--------|
| Zero cost, zero setup | No Apple account, no certificate to expire, no secrets in CI. |
| Reproducible | `git clone` → tag push → DMG. Nothing else required. |
| No credential-expiry failures | Certificates expire; ad-hoc signatures do not. |
| Signatures are still present | The bundle is signed, so `codesign --verify` succeeds and macOS treats it as a normal (if unverifiable) app. |

**Negative**

| Cost | Mitigation |
|------|------------|
| Gatekeeper blocks first launch with "developer cannot be verified". | Documented. Users right-click → **Open** once, or run `xattr -cr`. |
| No publisher identity — users cannot cryptographically verify the app. | Stated plainly in the README and user guide. Users must trust the download source. |
| The app's own **Gatekeeper** toggle is ironic — it ships unsigned. | Documented as a known consequence, not hidden. |
| No notarization ticket, so the warning never fully disappears. | Accepted for the project's scope. |

### Alternatives considered

| Alternative | Why rejected |
|-------------|--------------|
| Apple Developer Program + Developer ID + notarization | US$99/year and an annual renewal obligation. Out of proportion for a free 8-feature utility. |
| Distribute as a completely unsigned `.app` | Strictly worse: signature-less bundles produce more severe Gatekeeper behaviour and cannot be verified even structurally. |
| Ship source only | Defeats the purpose of a DMG distribution. |
| Homebrew Cask | Requires the app to be in a Homebrew tap; does not remove the signing problem and adds a distribution dependency. |

### Revisit when
The project gains a maintainer with a Developer Program membership, or complaints about the
Gatekeeper warning become the dominant support issue.

---

## ADR-004: `create-dmg` for macOS disk images

**Status:** Accepted · **Date:** 2026-09-29

### Context
The release artefact is a `.dmg` with a drag-to-Applications layout, built automatically in CI.

### Decision
Use **`create-dmg`** (`brew install create-dmg`) rather than hand-rolling `hdiutil` commands.

### Rationale
A drag-to-install DMG is the universally understood macOS install pattern, and getting the
`/Applications` symlink, icon positions, and window geometry right by hand is a fiddly, error-prone
`hdiutil` incantation. `create-dmg` wraps that in one declarative, well-tested command and is the
de-facto standard for open-source macOS projects.

### Consequences

**Positive**

| Benefit | Detail |
|---------|--------|
| Idiomatic install UX | Drag to Applications, exactly what users expect. |
| Reproducible output | The same flags produce the same layout on every runner. |
| Maintained upstream | Actively used by widely-deployed open-source macOS apps. |
| Cross-platform CI | Runs on any `macos-latest` runner with Homebrew preinstalled. |

**Negative**

| Cost | Mitigation |
|------|------------|
| An external Homebrew dependency in CI. | Installed explicitly in its own step, so a failure is clearly attributable. |
| Less control over low-level DMG layout than raw `hdiutil`. | Accepted — the extra flexibility is not needed for a single-app image. |
| Icon positions are hard-coded pixel coordinates. | Documented in [CI-CD.md §4](CI-CD.md#step-8--create-dmg) so they can be tuned knowingly. |

### Command used

```bash
cd dist
create-dmg \
  --volname "Rosetta Stone Installer" \
  --window-pos 200 120 \
  --window-size 600 400 \
  --icon-size 100 \
  --icon "RosettaStone-AppleSilicon.app" 150 190 \
  --hide-extension "RosettaStone-AppleSilicon.app" \
  --app-drop-link 450 190 \
  --no-internet-enable \
  "RosettaStone-AppleSilicon.dmg" \
  "RosettaStone-AppleSilicon.app" \
  || true
```

| Flag | Purpose |
|------|---------|
| `--volname` | Volume name shown on mount. |
| `--window-pos` / `--window-size` | Finder window position and size inside the image. |
| `--icon` / `--app-drop-link` | App icon at (150, 190), /Applications symlink at (450, 190). |
| `--hide-extension` | Hides the `.app` extension so the mounted volume reads as a clean name. |
| `--no-internet-enable` | Skips the `.DS_Store` artwork step — deterministic and faster. |
| `\|\| true` | The following *Verify DMG* step independently fails on a missing or empty image, so a non-zero exit here is tolerated without risking a silent bad upload. |

### Alternatives considered

| Alternative | Why rejected |
|-------------|--------------|
| Raw `hdiutil create` + manual layout | Significantly more code for an identical result, and far easier to get wrong. |
| `swift package generate-dmg` / `appdmg` | A dependency for a task a single Homebrew tool already solves well. |
| `dmgbuild` | A Python tool; a heavier CI dependency than `create-dmg`, which is Homebrew-native. |
| A `.zip` containing the `.app` | Loses the drag-to-install affordance and looks amateur for a GUI utility. |

---

## ADR-005: Per-architecture DMGs via a CI matrix

**Status:** Accepted · **Date:** 2026-09-29

### Context
Rosetta Stone must support both **Intel x64** and **Apple Silicon arm64**.

### Decision
Build **two separate single-architecture DMGs** using a GitHub Actions matrix, and publish both to
every release.

```yaml
matrix:
  include:
    - arch: arm64
      output_name: RosettaStone-AppleSilicon
    - arch: x86_64
      output_name: RosettaStone-Intel
```

Both legs run on `macos-latest`. Artefacts: `RosettaStone-AppleSilicon-dmg` and
`RosettaStone-Intel-dmg`, containing `RosettaStone-AppleSilicon.dmg` and `RosettaStone-Intel.dmg`.

### Rationale
A single **universal** binary is simpler for the user (one download, always the right slice), but it
carries real costs: roughly double the download size for everyone, and a genuine risk of a user
accidentally launching the translated slice — which is slow and confusing, and is exactly the class
of problem this app exists to fix. Two clearly-named DMGs make the choice explicit at download time.

The Intel leg **cross-compiles** on the Apple Silicon runner: `xcodebuild ARCHS=x86_64` emits Intel
code from an arm64 host, so no Intel machine is needed in CI. `ONLY_ACTIVE_ARCH=NO` is essential
here — without it, Xcode emits a host-architecture binary mislabelled as Intel.
`fail-fast: false` ensures one architecture failing does not cancel the other.

### Consequences

**Positive**

| Benefit | Detail |
|---------|--------|
| Half the download size per user. | Each binary contains only the slice it needs. |
| No accidental wrong-slice launch. | Users must consciously pick their architecture. |
| Self-documenting artefacts. | The filename states the architecture, so support requests are unambiguous. |
| Extensible. | A third architecture joins the matrix and is picked up by the `artifacts/*.dmg` glob automatically. |
| Simpler runtime behaviour. | A single-arch binary never needs a translation layer — which matters for a tool whose own Rosetta toggle could otherwise be self-referential. |

**Negative**

| Cost | Mitigation |
|------|------------|
| Two downloads to name and document. | Clearly named in the README and user guide. |
| Twice the build time. | Roughly 2–4 minutes in total; acceptable. |
| Risk of publishing mismatched versions. | `needs: build` plus the single glob in the release job mean one version tag produces exactly one matched pair. |

### Alternatives considered

| Alternative | Why rejected |
|-------------|--------------|
| One universal binary / DMG | ~2× download size; wrong-slice launches are a real and confusing failure mode for this specific audience. |
| Two DMGs each containing both apps | Confusing install UX — users must know which app to drag. |
| Build the Intel leg on a real Intel runner | Doubles CI cost for no benefit; Xcode cross-compiles reliably. |
| A `lipo`-merged binary published from one DMG | The same download-size objection as the universal binary, plus a merge step that can silently fail. |

---

## ADR-006: Privilege escalation via `osascript … with administrator privileges`

**Status:** Accepted · **Date:** 2026-09-29

### Context
Seven of the eight features require root: `spctl --master-disable`, `nvram AutoBoot=%00`,
`softwareupdate --install-rosetta`, `mdutil -E /`, `dscacheutil -flushcache`,
`killall -HUP mDNSResponder`, `rm -rf /Library/Caches/*`, and the `launchctl` launch-agent write.
The app must work on macOS 10.15, be distributed ad-hoc signed (ADR-003), and never handle a
password itself.

### Decision
Route every privileged command through a single choke point — `SystemCommands.runAsAdmin(_:timeout:)` —
which spawns:

```bash
osascript -e 'do shell script "<command>" with administrator privileges'
```

### Rationale
This is the only escalation mechanism that satisfies all four constraints simultaneously. It has
been available since macOS 10.0, requires no certificate, no privileged helper binary, no
`SMJobBless` entitlement, and no in-app password field. The user sees the standard macOS
Authorization Services dialog, which is both familiar and the correct security boundary — the app
never sees the credential.

`SMJobBless` would be the "proper" Apple-blessed approach, but it requires a Developer ID
certificate and a signed installer, which ADR-003 has already ruled out. An in-app password field
would be a serious security anti-pattern.

### Consequences

**Positive**

| Benefit | Detail |
|---------|--------|
| No credentials ever reach the app. | Authorization Services handles authentication entirely. |
| No certificate or helper binary required. | Compatible with ad-hoc distribution. |
| Works on macOS 10.15 → 27. | The `with administrator privileges` clause is stable across the whole range. |
| Familiar UI. | Users recognise the system dialog and understand what it means. |
| One auditable choke point. | All elevation lives in `Services/SystemCommands.swift`, reviewable in isolation. |

**Negative**

| Cost | Mitigation |
|------|------------|
| A user prompt per privileged action. | Accepted — it is the correct security behaviour. State **reads** are unprivileged, so merely opening the window never prompts. |
| The inner command is interpreted by `/bin/sh`. | Every interpolated value is single-quote escaped with `'\''`. No user input, URL parameter, or runtime-discovered filename is ever interpolated raw. |
| AppleScript quoting (`"`, `\`) must be escaped before shell quoting. | Two-stage escaping is centralised in one function and unit-tested, rather than repeated per feature. |
| `osascript` error `-128` on cancel must be distinguished from a real failure. | `SystemCommands` maps `-128` to `.cancelled`; the UI reverts silently with no error alert. |
| No non-interactive operation is possible. | An automation still requires a human password prompt. Documented in [USER-GUIDE.md §9.7](USER-GUIDE.md#97-automation-notes). |

### Alternatives considered

| Alternative | Why rejected |
|-------------|--------------|
| `SMJobBless` privileged helper tool | Requires a Developer ID certificate and signed installer — incompatible with ad-hoc signing (ADR-003). |
| In-app password field, then `sudo -S` | Major security anti-pattern: the app would handle a raw admin password. |
| `AuthorizationExecuteWithPrivileges` | Deprecated since macOS 10.7 and has no place in a modern app. |
| `sudo` via `NSTask`/`Process` | Requires a TTY; non-interactive sudo depends on credential caching a GUI app cannot rely on. |
| AppleScript executed in-process via `NSAppleScript` | Functionally equivalent, but keeps privileged automation inside the app's own process. Spawning `osascript` keeps the privilege boundary in a separate, auditable process. |

---

## ADR-007: CPU architecture detection with `uname -m`

**Status:** Accepted · **Date:** 2026-09-29

### Context
Two features are CPU-gated: **Auto Boot** (Intel only) and **Rosetta 2** (Apple Silicon only). The
app must detect the host architecture at runtime, on macOS 10.15 through 27.

### Decision
Run `/usr/bin/uname -m` **once at launch**, cache the result, and derive feature availability from it.

| Output | `CPUArchitecture` | Auto Boot | Rosetta 2 |
|--------|-------------------|-----------|-----------|
| `arm64` | `.arm64` | Disabled (greyed + 🔒) | Enabled |
| `x86_64` | `.x86_64` | Enabled | Disabled (greyed) |
| anything else | `.unknown` | Disabled | Disabled |

### Rationale
`uname -m` is POSIX, has existed since macOS 10.0, requires no API availability check, and needs a
single process spawn at launch. The compile-time alternative (`#if arch(arm64)`) cannot work: a
single binary must branch on the **host** at runtime, not on the slice it was compiled for.

Detection is **fail-safe**: an unrecognised architecture disables both features rather than
guessing, because wrongly enabling an `nvram` write is a far worse outcome than a greyed-out row.

Critically, the `x86_64` result is used **only** to gate UI availability, never to decide whether
Rosetta 2 is *installed*. An arm64 Mac running an x86_64 process under Rosetta reports `x86_64` from
`uname -m`, so the installed-state check uses the filesystem probe
`/usr/libexec/oah/libRosettaRuntime` instead — see
[ARCHITECTURE.md §5](ARCHITECTURE.md#5-hardware-detection).

### Consequences

**Positive**

| Benefit | Detail |
|---------|--------|
| Works on every supported OS version. | No `@available` checks, no API deprecation risk. |
| One spawn at launch. | Cached; zero cost during normal UI interaction. |
| Familiar and debuggable. | A user can reproduce the exact check in Terminal. |
| Explicit unknown state. | A future architecture degrades to disabled rather than to a wrong guess. |

**Negative**

| Cost | Mitigation |
|------|------------|
| Requires spawning a process at launch. | Once, off the critical path, on a background queue. |
| Under Rosetta, `uname -m` reports the translated architecture. | Acceptable: the result only gates the UI; the Rosetta 2 *installed* check uses a filesystem probe instead. |
| Output is a string that must be parsed. | Parsed with an exhaustive `switch` and an explicit `.unknown` default. |

### Alternatives considered

| Alternative | Why rejected |
|-------------|--------------|
| `sysctlbyname("hw.optional.arm64")` | Available from macOS 11.0 only — unusable on the 10.15 floor. |
| `ProcessInfo.processInfo.isTranslated` | Reports whether the **process** is translated, not what the host CPU is. Correct question, wrong tool. |
| `#if arch(arm64)` / `#if os(...)` | Compile-time. A single binary cannot branch on the host at runtime. |
| `NXGetLocalArchInfo()` | Deprecated since macOS 10.9. |
| Rosetta-runtime detection alone | Cannot distinguish "Intel Mac" from "arm64 Mac running under Rosetta". |

---

## ADR-008: Gate Auto Boot on a full `MacProfile` (model + form factor + architecture)

**Status:** Accepted · **Date:** 2026-10-01

### Context

ADR-007 gated Auto Boot on `uname -m` alone: `.x86_64` → available, everything else → locked. That was
wrong in a way the architecture test structurally cannot catch.

Auto Boot means *"power on when the lid is opened"*. **Every Intel desktop passes `uname -m`.** An
iMac, a Mac mini, a Mac Studio and a Mac Pro all report `x86_64`, all four were offered a live
toggle, and on Intel desktop firmware `nvram AutoBoot` is absent or has no effect. The user could
toggle a row that does nothing, or raise an Authorization dialog for a write the firmware discards.

The app therefore needs a **second, independent fact** about the machine — laptop or desktop — which
the CPU architecture cannot supply.

### Decision

Introduce `MacProfile` (`RosettaStone/Services/MacProfile.swift`): the model name, the form factor
derived from it, and the already-detected `CPUArchitecture`. It becomes the single source of truth for
availability, and `FeatureID.availability(on:)` takes the profile rather than a bare architecture.

```swift
var supportsAutoBoot: Bool {
    formFactor == .laptop && cpuArchitecture == .x86_64
}
```

Detection order, both sources unprivileged and read-only:

1. **`/usr/sbin/system_profiler SPHardwareDataType`** — parsed in Swift for the `Model Name` field.
2. **`/usr/sbin/sysctl -n hw.model`** — the fallback, when the profiler fails, times out (20 s budget),
   or prints no model name.

### Rationale

**Why parse `system_profiler` in Swift instead of piping through `grep "Model Name"`**

- **Consistency with the rest of the command set.** Every other external command in the app is a
  constants-only executable + argument vector through `SystemCommands.run` (`docs/ARCHITECTURE.md` §6,
  layering rule 3). A shell fragment would have been the only string with a shell in it, and therefore
  the only place a quoting mistake could turn a read into something else.
- **Testability.** `MacProfile.parseModelName(from:)` is a pure function of a string, so the parser is
  exercised against real transcripts on **any** platform. A `grep` pipeline can only be verified on a
  Mac, which is exactly where CI cannot run it.
- **Locale-robustness.** The comparison is case-insensitive because `system_profiler` follows the
  process locale; a `grep "Model Name"` would silently find nothing under a non-English locale.

**The `hw.model` blind spot on M-series — and why it is acceptable**

From the M-series generation Apple stopped encoding the product family in the machine identifier. An M1
MacBook Pro is `MacBookPro18,3`, but a 14-inch M2 Pro is `Mac14,5` — a bare `Mac` plus two numbers
that say nothing about the chassis. That string is **not classifiable**, so it yields `.unknown`.

This is precisely why `system_profiler` is the **primary** source and `hw.model` only a fallback, and
why the fallback is anchored on **prefixes** rather than substrings. The blind spot is also harmless in
practice: every unclassifiable M-series machine is Apple Silicon, where Auto Boot is locked on
architecture regardless. The fallback therefore only ever needs to work on **Intel** hardware, where
`hw.model` still carries the family.

**Why `.unknown` fails safe**

`.unknown` is a first-class answer, not an error case — `system_profiler` can be slow, blocked by
policy, or missing from a trimmed system image. It **locks** the row, matching the rule ADR-007 already
established for an unrecognised `CPUArchitecture`: a wrongly-enabled `nvram` write is permanent,
unrecoverable through the app, and far worse than a greyed row that explains itself. A future form
factor is deliberately **not** assumed to be a desktop, because guessing desktop would wrongly
*unlock* Auto Boot on a hypothetical new chassis.

**Where the committed test harness lives**

`tests/MacProfileTests.swift` — **39 assertions**, self-contained and runnable off-macOS:

```bash
swiftc -swift-version 5 -o macprofile-tests tests/MacProfileTests.swift
./macprofile-tests
```

It is committed rather than kept as a scratch file because this gate is the one place in the app where
a wrong answer writes firmware settings, and it must be provable without a Mac in the loop. It stubs
`CPUArchitecture` and the two `SystemCommands` symbols `MacProfile.detect()` needs, then exercises the
classification, the parser, the gate and the lock reasons. `detect()` itself is deliberately **not**
covered — it is I/O, and it is verified on-device through the Diagnostics report, which now prints the
model, form factor, gate result and reason.

### Consequences

**Positive**

| Benefit | Detail |
|---------|--------|
| Intel desktops are correctly locked. | The original bug: an iMac no longer offers a toggle that cannot work. |
| One rule, not two. | `CPUArchitecture.supportsAutoBoot` was **removed**; `FeatureID.availability(on:)` asks the profile, so no duplicate logic can drift. |
| Every lock explains itself. | `autoBootDisabledReason` is non-`nil` whenever the row is locked, and feeds both the subtitle and the tooltip. |
| The gate is provable in CI. | 39 assertions run on any platform from a bare `swiftc`. |
| Diagnosis is self-service. | Diagnostics reports the model, form factor, gate and reason, so a greyed row is verifiable from a copied report. |

**Negative**

| Cost | Mitigation |
|------|------------|
| `system_profiler` is slow on a cold cache. | Given a 20 s budget (vs 5 s for `uname -m`) and falls back to `hw.model`; detected once per process, off the critical path. |
| An extra process spawn at launch. | Same as ADR-007: once, cached in `MacProfile.current`. |
| The harness duplicates the logic under test. | Stated explicitly in the file header; the copied code is verbatim with matching type names, and `MacProfile.swift` is small and pure. |

### Alternatives considered

| Alternative | Why rejected |
|-------------|--------------|
| Keep `uname -m` and lock only on `arm64` | The original rule. Wrong for every Intel desktop. |
| Guess the form factor from `hw.model` only | Blind on M-series (`Mac14,5`), and adds a process spawn for a value `system_profiler` already provides. |
| Assume an unrecognised model is a desktop, so Auto Boot stays off | Wrong direction: it would *unlock* Auto Boot on a future form factor that does have a lid. `.unknown` must lock. |
| Ask the user instead of detecting | Auto Boot is a system toggle; a prompt at launch contradicts "opening the window costs nothing" (`docs/ARCHITECTURE.md` §4). |
| `grep "Model Name"` in a shell pipeline | See rationale above: shell fragment, untestable off-macOS, locale-fragile. |

---

## Revisit triggers

| ADR | Revisit if |
|-----|-----------|
| 001 | The minimum supported macOS version rises to 13 or later, making `MenuBarExtra` viable. |
| 002 | The same — App Intents become usable and offer better Shortcuts discoverability. |
| 003 | The project obtains a Developer Program membership, or Gatekeeper friction becomes the top support issue. |
| 004 | `create-dmg` becomes unmaintained, or the DMG needs non-standard layout features. |
| 005 | An architecture beyond arm64/x64 ships, or download size becomes a measured problem. |
| 006 | The app adopts a signed installer, which would permit `SMJobBless` and remove the per-action prompt. |
| 007 | `uname -m` behaviour changes, or a supported OS version drops the command. |
| 008 | Apple restores the product family to `hw.model` on Apple Silicon, or a new form factor appears that would make `.unknown` a wrong answer rather than a safe one. |




