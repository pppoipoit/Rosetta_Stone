<h1 align="center">Rosetta Stone</h1>

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
- **Menu-bar resident.** The app is an `LSUIElement` agent: it lives in the menu bar and can
  hide its window entirely, so it never occupies Dock space or interrupts focus.
- **Broad OS floor.** It must run on macOS 10.15, which rules out modern-only frameworks.

---

## Features

| # | Feature | Control | Command | Admin? | Availability |
|---|---------|---------|---------|--------|--------------|
| 1 | Run at Startup | Toggle | `create` / `remove` `~/Library/LaunchAgents/com.rosettastone.helper.plist` | **Yes** (admin) | All |
| 2 | Gatekeeper | Toggle | `spctl --master-disable` / `spctl --master-enable` | **Yes** (admin) | All |
| 3 | Hidden Files | Toggle (ON = show) | `defaults write com.apple.finder AppleShowAllFiles YES/NO` + `killall Finder` | No | All |
| 4 | Auto Boot | Toggle | `nvram AutoBoot=%03` / `nvram AutoBoot=%00` | **Yes** (admin) | Intel only; greyed + lock icon on Apple Silicon |
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
Auto Boot           [ lock ]  /  [ toggle ]     <- Intel only
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
| Runtime dependencies | None. System tools only: `spctl`, `nvram`, `mdutil`, `dscacheutil`, `defaults`, `killall`, `softwareupdate`. |

**Feature 4 (Auto Boot)** is Intel-only and **Feature 5 (Rosetta 2)** is Apple-Silicon-only. The
UI greys out the inapplicable row and shows a lock icon rather than hiding it, so the feature list
stays visually stable across machines.

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

5. The app appears in the **menu bar** (a stone glyph), *not* the Dock — this is intentional.
   Click the glyph to open the panel.
6. Enable the **Run at Startup** toggle to install the login item so the menu-bar icon returns
   after every reboot.

---

## Build from source

```bash
git clone https://github.com/<owner>/Rosetta_Stone.git
cd Rosetta_Stone
```

**Requirements:** macOS 11+ host, Xcode 12.5 or newer.

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
>   afterwards.
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
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Process model, startup flow, URL-scheme flow, privilege escalation, CPU detection — with Mermaid diagrams |
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
├── RosettaStone/          Swift sources (added in the implementation phase)
│   ├── App/               App + AppDelegate entry points
│   ├── Models/            Feature / CPU / toggle state models
│   ├── Resources/         Assets.xcassets
│   ├── Services/
│   │   ├── Privileges/    osascript escalation layer
│   │   └── System/        Command execution, LaunchAgent, CPU detection
│   ├── Support/           Info.plist, entitlements
│   └── Views/
│       ├── Main/          Main window
│       └── MenuBar/       NSStatusItem panel
├── scripts/               Developer helper scripts
└── assets/                Icons and screenshots
```

---

## Licence

See the repository's `LICENSE` file.
