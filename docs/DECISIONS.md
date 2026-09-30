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
| Icon positions are hard-coded pixel coordinates. | Documented in [CI-CD.md §4](CI-CD.md#step-12--create-dmg) so they can be tuned knowingly. |

### Command used

```bash
create-dmg \
  --volname "Rosetta Stone" \
  --window-size 660 400 \
  --icon-size 180 \
  --icon "Rosetta Stone.app" 180 170 \
  --app-drop-link 480 170 \
  --no-internet-enable \
  build/RosettaStone-AppleSilicon.dmg \
  "Rosetta Stone.app"
```

| Flag | Purpose |
|------|---------|
| `--volname` | Volume name shown on mount. |
| `--window-size` | Finder window size inside the image. |
| `--icon` / `--app-drop-link` | App icon at (180, 170), /Applications symlink at (480, 170). |
| `--no-internet-enable` | Skips the `.DS_Store` artwork step — deterministic and faster. |

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
    - os: osx-arm64
      app_name: RosettaStone-AppleSilicon
      arch: arm64
    - os: osx-x64
      app_name: RosettaStone-Intel
      arch: x86_64
```

Artefacts: `RosettaStone-AppleSilicon.dmg` and `RosettaStone-Intel.dmg`.

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
Route every privileged command through a single `PrivilegeEscalator` that spawns:

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
| One auditable choke point. | All elevation lives in `Services/Privileges/PrivilegeEscalator`, reviewable in isolation. |

**Negative**

| Cost | Mitigation |
|------|------------|
| A user prompt per privileged action. | Accepted — it is the correct security behaviour. State **reads** are unprivileged, so merely opening the window never prompts. |
| The inner command is interpreted by `/bin/sh`. | Every interpolated value is single-quote escaped with `'\''`. No user input, URL parameter, or runtime-discovered filename is ever interpolated raw. |
| AppleScript quoting (`"`, `\`) must be escaped before shell quoting. | Two-stage escaping is centralised in one function and unit-tested, rather than repeated per feature. |
| `osascript` error `-128` on cancel must be distinguished from a real failure. | `PrivilegeEscalator` maps `-128` to `.cancelled`; the UI reverts silently with no error alert. |
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
[ARCHITECTURE.md §5](ARCHITECTURE.md#5-cpu-detection).

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




