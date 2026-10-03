<h1 align="center">Rosetta Stone</h1>

![CI Status](https://github.com/pppoipoit/Rosetta_Stone/actions/workflows/build-mac-dmg.yml/badge.svg) ![macOS 10.15 Catalina → 27 Golden Gate](https://img.shields.io/badge/macOS-10.15%20Catalina%20%E2%86%92%2027%20Golden%20Gate-0078d4?logo=apple) ![Swift 5 language mode](https://img.shields.io/badge/Swift-5.0%20language%20mode-orange?logo=swift) ![Architecture arm64 | x86_64](https://img.shields.io/badge/Arch-arm64%20%7C%20x86__64-lightgrey?logo=apple) ![License MIT](https://img.shields.io/badge/License-MIT-green)

<p align="center">
  <b>A native macOS utility for power-user system toggles.</b><br>
  SwiftUI dark-theme UI + AppKit <code>NSStatusItem</code> menu-bar residency.<br>
  macOS 10.15 Catalina &rarr; macOS 27 Golden Gate &middot; Intel x64 &amp; Apple Silicon arm64
</p>

---

## Purpose

Rosetta Stone bundles the handful of hidden macOS settings that power users constantly
re-enable or reset — startup items, Gatekeeper, hidden files, Auto Boot, Rosetta 2 — plus a
small set of one-shot maintenance commands (Spotlight rebuild, DNS flush, cache clear) behind
a single, fast, keyboard-free interface.

It is a *thin, honest GUI over the CLI*. Every feature maps 1:1 to a command you could type in
Terminal. The value is not new capability; it is discoverability, state readback, and consistent
privilege prompting.

Design constraints that shape everything:

- **Zero onboarding / no account / no telemetry.** Nothing is uploaded. Nothing is tracked.
- **Two modes, one toggle.** *Run at Startup* **OFF** (the default) is a normal windowed app
  with a Dock icon and no menu-bar icon. **ON** is the power-user mode: a hidden-window
  `LSUIElement` menu-bar gadget — left-click toggles Gatekeeper, right-click opens the full
  menu, and all seven URL actions work. Flipping the toggle switches posture live, with no
  relaunch.
- **Broad OS floor.** It must run on macOS 10.15, which rules out modern-only frameworks.

---

## Features

| # | Feature | Control | Command | Admin? | Availability |
|---|---------|---------|---------|--------|--------------|
| 1 | Run at Startup | Toggle (mode switch) | `create` / `remove` `~/Library/LaunchAgents/com.rosettastone.helper.plist` | **Yes** (admin) | All |
| 2 | Gatekeeper | Toggle | `spctl --master-disable` / `spctl --master-enable` (macOS 15+: confirm “Anywhere” in System Settings) | **Yes** (admin) | All |
| 3 | Hidden Files | Toggle (ON = show) | `defaults write com.apple.finder AppleShowAllFiles YES/NO` + `killall Finder` | No | All |
| 4 | Auto Boot | Toggle | `nvram AutoBoot=%03` / `nvram AutoBoot=%00` | **Yes** (admin) | Intel MacBook only; greyed + lock icon on Apple Silicon *and* on desktops, with the reason shown inline |
| 5 | Rosetta 2 | Install button | `softwareupdate --install-rosetta --agree-to-license` | **Yes** (admin) | Apple Silicon only; greyed on Intel; installed-check via `/usr/libexec/oah/libRosettaRuntime` |
| 6 | Spotlight Rebuild | Button | `mdutil -E /` | **Yes** (admin) | All |
| 7 | DNS Flush | Button | `dscacheutil -flushcache` + `killall -HUP mDNSResponder` | **Yes** (admin) | All |
| 8 | Clear System Cache | Button | `rm -rf /Library/Caches/*` | **Yes** (admin) | All |

> Every command in the **Admin?** column marked *Yes* is executed with administrator privileges
> via `osascript -e '... with administrator privileges'` and therefore raises a macOS
> authentication dialog. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#5-privilege-escalation-strategy).

### UI layout (row order)

```
Run at Startup      [ toggle ]
Gatekeeper          [ toggle ]
Hidden Files        [ toggle ]
Auto Boot           [ lock ]  /  [ toggle ]     <- Intel MacBook only
Rosetta 2           [ Install ]                 <- Apple Silicon only
Quick Tools         [ Spotlight ] [ DNS ] [ Cache ]
```

Dark theme throughout. The **Quick Tools** block is a 3-column grid of transient action buttons —
none of them hold state.

Full behavioural detail, per-feature command strings, and edge cases: **[docs/FEATURES.md](docs/FEATURES.md)**.

---

## Requirements

| Item | Requirement |
|------|-------------|
| Operating system | macOS 10.15 (Catalina) or newer, up to macOS 27 (Golden Gate) |
| Architectures | Intel x64 and Apple Silicon arm64 (per-arch DMGs published) |
| Privileges | An administrator account. 7 of 8 features prompt for elevation. |
| Disk | < 50 MB |
| Network | Only for the Rosetta 2 install; all other features are fully offline |
| Runtime dependencies | None. System tools only: `spctl`, `nvram`, `mdutil`, `dscacheutil`, `defaults`, `killall`, `softwareupdate`. Read-only detection additionally uses `uname`, `system_profiler` and `sysctl`. |

**Feature 4 (Auto Boot)** works on **Intel MacBooks only** (`nvram AutoBoot=%03` / `%00`), and
**Feature 5 (Rosetta 2)** is Apple-Silicon-only. The UI greys out the inapplicable row and shows a
lock icon rather than hiding it, so the feature list stays visually stable across machines; the
locked row's subtitle **and** its hover tooltip both state the reason, so it always explains itself.

Auto Boot is locked for three reasons, and the app picks the one that matches your machine: Apple
Silicon (*"Apple Silicon reset NVRAM ทุกครั้งที่ cold boot"* — firmware owns the setting), a desktop
(*"Desktop Mac ไม่มีฝาเปิด-ปิด"* — there is no lid, and Intel desktop firmware ignores the
variable), or an unidentifiable model (the app fails safe). **Diagnostics…** reports *Model name*,
*Form factor*, *Auto Boot supported* and *Auto Boot lock reason*.

---

## Install from DMG

1. Download the DMG matching your machine from the Releases page:
   - `RosettaStone-AppleSilicon-<version>.dmg` — M-series Macs.
   - `RosettaStone-Intel-<version>.dmg` — Intel Macs.
2. Open the DMG and drag **Rosetta Stone** into **Applications**.
3. Eject the DMG.
4. Launch **Applications → Rosetta Stone**.

> **First-run warning — ad-hoc signature.** Release builds are **ad-hoc signed**
> (`codesign --sign -`), not signed with a paid Apple Developer ID. macOS Gatekeeper will
> report *"the app is damaged"* or *"cannot be opened because the developer cannot be
> verified"*, and the iCloud/Time Machine quarantine attribute applies. To clear it:
> right-click (Control-click) the app → **Open** → confirm in the dialog. Only do this if you
> trust the download.
> Full instructions: [docs/USER-GUIDE.md](docs/USER-GUIDE.md#first-launch).

5. The app opens as a **normal windowed app** with a Dock icon — the default mode. There is no
   menu-bar icon yet, so use the **Diagnostics…** link in the panel footer if you need the
   support report.
6. Turn **Run at Startup** ON whenever you want the power-user mode: the per-user login item is
   installed, the Dock icon disappears and a stone glyph appears in the menu bar.
   **Left-click** the glyph to toggle Gatekeeper — no window, just the password prompt and a
   small toast with the result; **right-click** it for the full menu (Open Main Window, Toggle
   Hidden Files, Flush DNS, Rebuild Spotlight, Clear System Cache…, Diagnostics…, Quit).
   Turning the toggle OFF removes the login item and the glyph, restores the Dock icon, and
   makes the app ordinary again — live, with no relaunch.

---

## Build from source

```bash
git clone https://github.com/<owner>/Rosetta_Stone.git
cd Rosetta_Stone
```

**Requirements:** macOS 11+ host, **Xcode 15 or newer**, and **XcodeGen 2.35+** (`brew install
xcodegen`). The `.xcodeproj` is generated from `project.yml` and is deliberately not committed,
so generate it first:

```bash
xcodegen generate
```

### Xcode

```bash
open RosettaStone.xcodeproj      # or RosettaStone.xcworkspace
# Product → Build   ⌘B
# Product → Run     ⌘R
```

### Command line (xcodebuild)

```bash
xcodebuild -project RosettaStone.xcodeproj \
           -scheme RosettaStone \
           -configuration Release \
           -derivedDataPath build \
           build
```

Per architecture:

```bash
xcodebuild -project RosettaStone.xcodeproj -scheme RosettaStone \
           -configuration Release ARCHS=arm64  ONLY_ACTIVE_ARCH=NO build

xcodebuild -project RosettaStone.xcodeproj -scheme RosettaStone \
           -configuration Release ARCHS=x86_64 ONLY_ACTIVE_ARCH=NO build
```

### Tests

The Auto Boot gate is the one rule in the app where a wrong answer writes firmware settings, so its
logic is covered by a committed harness that needs no Mac, no Xcode and no package manager:

```bash
swiftc -swift-version 5 -o macprofile-tests tests/MacProfileTests.swift
./macprofile-tests          # exit 0 == all 39 assertions passed
```

It exercises the model classification, the `system_profiler` parser, the availability rule and the
lock reasons. See `tests/MacProfileTests.swift` and
[ADR-008](docs/DECISIONS.md#adr-008).

This harness is **enforced in CI**: the `test` job runs it on `ubuntu-latest` *before* either build
leg, so a regression in the Auto Boot gate stops the pipeline instead of shipping a DMG.
See [docs/CI-CD.md](docs/CI-CD.md).

### Signing locally

Signing is **optional** for local runs. To strip the quarantine attribute that causes
first-launch friction during development:

```bash
xcrun codesign --force --deep --sign - RosettaStone.app
xattr -cr RosettaStone.app
```

For distribution, see [docs/CI-CD.md](docs/CI-CD.md) and the ad-hoc signing ADR in
[docs/DECISIONS.md](docs/DECISIONS.md).

---

## Shortcuts integration

Rosetta Stone registers the custom URL scheme `rosettastone://`, which can be driven from Apple
Shortcuts, Alfred, Raycast, or a shell script.

> **Requires the power-user mode.** URL actions run only while **Run at Startup** is ON (the
> menu-bar gadget). In the default mode the app is not running in the background, so the URLs
> are refused and the panel explains why.

| Action | URL |
|--------|-----|
| Open the app window | `rosettastone://open-app` |
| Toggle Gatekeeper | `rosettastone://toggle-gatekeeper` |
| Toggle Hidden Files | `rosettastone://toggle-hidden-files` |
| Flush DNS | `rosettastone://flush-dns` |
| Rebuild Spotlight index | `rosettastone://rebuild-spotlight` |
| Clear system cache | `rosettastone://clear-cache` |
| Install Rosetta 2 | `rosettastone://install-rosetta` |

Actions unavailable on the current CPU (e.g. `install-rosetta` on Intel) are ignored and logged
rather than raising an error.

Test from Terminal:

```bash
open "rosettastone://flush-dns"
```

Full wiring walkthrough: [docs/USER-GUIDE.md](docs/USER-GUIDE.md#5-apple-shortcuts).

---

## Security disclaimer

> ⚠️ **Read this before running anything.**
>
> Rosetta Stone executes privileged, system-modifying commands. Seven of the eight features
> require administrator rights and will prompt for your password through the standard macOS
> authentication dialog.
>
> - The application is distributed **ad-hoc signed and is not notarized**. There is no Apple
>   Developer ID chain of trust behind it, and no signing identity to attribute it to.
> - **Gatekeeper** (`spctl --master-disable`) (admin) turns off one of macOS's primary security
>   mechanisms. It permits unsigned and unnotarized software to run without warning. Only
>   disable it while you genuinely need to run an unsigned tool, and re-enable it immediately
>   afterwards. On **macOS 15 Sequoia and later** the command alone is not enough: the app opens
>   System Settings → Privacy & Security and asks you to choose **Anywhere** to confirm.
> - **Clear System Cache** (`rm -rf /Library/Caches/*`) (admin) deletes files in a shared system
>   location. Malformed caches can cause application instability, and some apps may need a
>   restart to regenerate their caches.
> - **Auto Boot** (`nvram AutoBoot=%00`) (admin) writes to NVRAM. An invalid or interrupted
>   write can leave a machine without automatic startup.
> - **Hidden Files** restarts Finder, which briefly blanks the desktop.
> - NVRAM writes and cache deletion are **not reversible** through the app.
>
> The software is provided **"as is", without warranty of any kind**. You are solely responsible
> for the state of your machine. Test on a non-critical system and keep a Time Machine or other
> backup current.

---

## Documentation map

| Document | Contents |
|----------|----------|
| [docs/FEATURES.md](docs/FEATURES.md) | Per-feature spec: command, admin flag, availability matrix, edge cases |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Process model, startup flow, URL-scheme flow, privilege escalation, hardware detection — with Mermaid diagrams |
| [docs/CI-CD.md](docs/CI-CD.md) | Line-by-line explanation of the GitHub Actions workflow |
| [docs/USER-GUIDE.md](docs/USER-GUIDE.md) | End-user manual, first-run warnings, Shortcuts recipes |
| [docs/DECISIONS.md](docs/DECISIONS.md) | ADRs: NSStatusItem vs MenuBarExtra, URL Scheme vs App Intents, ad-hoc signing, create-dmg, matrix builds |
| [CHANGELOG.md](CHANGELOG.md) | Keep-a-Changelog release history |

---

## Project layout

```
rosetta-stone/
├── .github/workflows/     CI pipeline (build-mac-dmg.yml)
├── docs/                  Specifications and manuals
├── scripts/               Developer helper scripts (first-run.sh)
├── tests/                 MacProfileTests.swift — 39-assertion harness, runnable off-macOS
├── RosettaStone/          Swift sources
│   ├── App/               main.swift, RosettaStoneApp, AppDelegate
│   ├── Models/            FeatureID, AppMode, CommandResult
│   ├── Resources/         Assets.xcassets
│   ├── Services/          SystemCommands, FeatureCoordinator(+Actions), StartupManager,
│   │                      SystemStateReader, CPUArchitecture, MacProfile, URLActionRouter,
│   │                      GatekeeperPolicy, Trace
│   ├── Support/           Info.plist, RosettaStone.entitlements
│   └── Views/
│       ├── Main/          ContentView, Components, Theme
│       └── MenuBar/       MenuBarController, StatusItemToast, DiagnosticsPanel
├── project.yml            XcodeGen spec — the source of truth for the build
├── CHANGELOG.md           Keep-a-Changelog history
├── LICENSE                MIT
└── README.md
```

---

## Licence

See the repository's `LICENSE` file.

---

## 🎨 Credits

Crafted with ❤️ by

**pppoipoit** × **DRKMTTR Studio**

*"Rosetta Stone — translating macOS complexity into a single click."*
