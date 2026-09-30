# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

Nothing yet.

---

## [0.1.0] — 2026-09-29

Initial release. Scaffolding, specifications, and CI pipeline. No application code has been
written yet — see the note at the end of this entry.

### Added

#### Features (specified; implementation lands in the next release)

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

#### Application shell

- SwiftUI dark-theme main window with the fixed row order: Run at Startup → Gatekeeper → Hidden
  Files → Auto Boot → Rosetta 2 → Quick Tools (Spotlight / DNS / Cache).
- AppKit `NSStatusItem` menu-bar residency, chosen over `MenuBarExtra` for macOS 10.15 support
  ([ADR-001](docs/DECISIONS.md#adr-001)).
- `LSUIElement` agent behaviour: no Dock icon, menu-bar glyph only, window shown on demand.
- Background startup posture — the app launches with no window and waits in the menu bar.
- CPU-architecture gating via `uname -m`, with greyed-out rows and a lock icon for inapplicable
  features ([ADR-007](docs/DECISIONS.md#adr-007)).
- Single serial execution queue so only one privileged operation runs at a time.

#### Shortcuts integration

- Custom URL scheme `rosettastone://` registered via `CFBundleURLTypes`, chosen over App Intents for
  macOS 10.15 support ([ADR-002](docs/DECISIONS.md#adr-002)).
- Actions: `open-app`, `toggle-gatekeeper`, `toggle-hidden-files`, `flush-dns`,
  `rebuild-spotlight`, `clear-cache`, `install-rosetta`.
- Allow-list validation with silent discard of unknown or CPU-inapplicable actions.

#### Security and packaging

- Privilege escalation through `osascript … with administrator privileges`, with all state reads
  kept unprivileged ([ADR-006](docs/DECISIONS.md#adr-006)).
- Shell-escaping of every interpolated command value; no user or URL input is ever passed raw.
- Non-sandboxed entitlements tuned for spawning system tools; hardened runtime intentionally off.
- `Info.plist` with `CFBundleIdentifier` `com.rosettastone.app`, `LSMinimumSystemVersion` 10.15,
  and `LSUIElement` true.
- Ad-hoc code signing, no Developer ID, no notarization
  ([ADR-003](docs/DECISIONS.md#adr-003)).
- `Assets.xcassets` scaffold for the app icon and status-bar glyph.

#### Continuous integration

- GitHub Actions workflow `.github/workflows/build-mac-dmg.yml`, adapted from a .NET reference
  pipeline.
- Triggers: `workflow_dispatch` and tag pushes matching `v*`.
- Two-architecture build matrix: `osx-arm64` → `RosettaStone-AppleSilicon.dmg`,
  `osx-x64` → `RosettaStone-Intel.dmg` ([ADR-005](docs/DECISIONS.md#adr-005)).
- `xcodebuild` Release builds with `ARCHS` and `ONLY_ACTIVE_ARCH=NO` for Intel cross-compilation.
- Version stamping into `CFBundleShortVersionString` / `CFBundleVersion` via `PlistBuddy`.
- Ad-hoc `codesign --force --deep --sign -` plus `codesign --verify`.
- `create-dmg` drag-to-Applications disk images ([ADR-004](docs/DECISIONS.md#adr-004)).
- DMG verification with `hdiutil verify` and `7z l` before upload.
- Artifact upload per architecture via `actions/upload-artifact@v4`.
- `release` job on `ubuntu-latest` gated on `refs/tags/v`, using `actions/download-artifact@v4`
  and `softprops/action-gh-release@v2` with `generate_release_notes: true`.

#### Documentation

- `README.md` — purpose, feature table, requirements, install and build instructions, Shortcuts
  usage, and a full security disclaimer.
- `docs/FEATURES.md` — per-feature specification with exact commands, permission and availability
  matrices, and edge cases.
- `docs/ARCHITECTURE.md` — process model, LaunchAgent startup flow, URL-scheme flow, privilege
  escalation, and CPU detection, with Mermaid diagrams for each flow.
- `docs/CI-CD.md` — step-by-step explanation of every job and step in the workflow.
- `docs/USER-GUIDE.md` — end-user manual including first-launch Gatekeeper guidance and
  step-by-step Apple Shortcuts wiring for every URL action.
- `docs/DECISIONS.md` — seven ADRs covering `NSStatusItem` vs `MenuBarExtra`, URL scheme vs App
  Intents, ad-hoc signing, `create-dmg`, matrix builds, privilege escalation, and CPU detection.
- `CHANGELOG.md` — this file.

#### Repository scaffolding

- Directory structure for `App/`, `Models/`, `Resources/`, `Services/Privileges/`,
  `Services/System/`, `Support/`, `Views/Main/`, `Views/MenuBar/`, `scripts/`, and `assets/`,
  with `.gitkeep` placeholders in empty directories.
- `.gitignore` covering Xcode, SwiftPM, DMG artefacts, and signing secrets.

### Changed

Nothing — this is the first release.

### Deprecated

Nothing.

### Removed

Nothing.

### Security

- Privilege escalation is centralised in a single auditable choke point; no credentials are ever
  handled by the app.
- The `clear-cache` action requires an explicit confirmation in addition to the macOS
  authentication prompt, including when triggered through the URL scheme.
- `osascript` cancellation (error `-128`) is mapped to a distinct "cancelled" result and produces no
  error alert.
- All build-time state reads are unprivileged, so opening the window never triggers a password
  prompt.

### Notes

This release contains **no application code**. It is the scaffolding and documentation phase:
folders, configuration, and specifications only. The feature table above is the agreed
specification, not a shipped capability. The CI workflow is complete and validated, but its
`xcodebuild` step will fail until an Xcode project exists.

---

[Unreleased]: https://github.com/<owner>/Rosetta_Stone/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/<owner>/Rosetta_Stone/releases/tag/v0.1.0


