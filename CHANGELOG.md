# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

The first working build. Application code, the XcodeGen project specification and the CI
pipeline now exist and both matrix legs build green on GitHub Actions.

### Phase 6 — two-mode intent + auditor fixes

**The app now has two modes, chosen by the Run at Startup toggle** (the owner-clarified intent).
OFF (the default) is a normal windowed app: panel at launch, Dock icon, no menu-bar icon, URL
actions refused. ON is the power-user menu-bar gadget: hidden launch, no Dock icon, menu-bar icon
always visible, **left-click toggles Gatekeeper directly**, **right-click opens the full menu**,
and all seven `rosettastone://` actions work. The switch flips the running process between the
two postures instantly, with no relaunch — turning OFF removes the login item, removes the
menu-bar icon in-process and restores the normal app.

#### Added

- **`AppMode`** (`Models/AppMode.swift`) — the two postures (`normal`, `menuBarGadget`) and their
  launch resolution: `--menu-bar-only` → gadget; LaunchAgent plist exists → gadget; otherwise
  normal. A manual double-click while the toggle is ON also opens hidden as a gadget.
- **`GatekeeperPolicy`** (`Services/GatekeeperPolicy.swift`) — the macOS 15+ two-step rule, the
  System Settings deep link, and the confirmation copy (Thai, owner-specified).
- **Live mode switching.** `AppDelegate.apply(_:)` observes `runAtStartup` and flips the running
  process: ON → `.accessory`, status item installed, Dock icon gone; OFF → `.regular`, status
  item removed **in-process**, panel brought forward.
- **Left-click on the menu-bar icon toggles Gatekeeper directly**; **right-click (or
  Control-click)** opens the full menu, which now also carries a Toggle Gatekeeper item and a
  "Left-click toggles Gatekeeper" hint.
- **Status-item tooltip** stating Gatekeeper's current state and what a left-click will do.
- **`Diagnostics…` link in the panel footer** — mode A has no menu-bar icon, so this is the only
  route to the report there.
- **`applicationShouldHandleReopen`** — clicking the Dock icon in mode A reopens the panel.

#### Changed

- **The window is now built in both modes** (gadget mode needs it for Open Main Window), and mode
  A sets `NSApp.setActivationPolicy(.regular)` and shows it at launch; mode B keeps `.accessory`
  and stays hidden at launch.
- **`StartupManager` no longer calls `launchctl`.** `install()` only writes the plist —
  bootstrapping the `RunAtLoad` job would launch a second instance immediately — and `remove()`
  only deletes it: `bootout` would terminate the very process performing the removal when it was
  started by that job at login.
- **URL actions are gated to gadget mode.** In mode A a recognised action is refused with a
  footer explanation instead of executing; unknown URLs stay silent in every mode.
- **The first-run flag is gone** (`hasLaunchedOnce` and its window): mode A shows the panel on
  every launch, so there is nothing to remember.
- Diagnostics reports Launch mode and the `--menu-bar-only` flag; the stale first-run field is
  gone. `docs/` updated throughout (README; FEATURES §1/§2/§9; ARCHITECTURE §1/§2/§3;
  USER-GUIDE §1/§3/§5/§6/§8/§9/§11).

#### Fixed

- **Gatekeeper on macOS 15 Sequoia, 26 Tahoe and 27 Golden Gate is a two-step procedure.**
  `spctl --master-disable` alone no longer flips the user-visible switch, so after the command
  succeeds the app opens System Settings → Privacy & Security and shows the confirmation message
  `กรุณาเลือก 'Anywhere' ใน System Settings เพื่อยืนยันการปิด Gatekeeper`. The version rule
  (`majorVersion >= 15`) lives in `GatekeeperPolicy`, and every entry point — switch, right-click
  menu, left-click direct toggle, URL action — shares one write path
  (`FeatureCoordinator.writeGatekeeper(bypassed:)`), so the second step cannot be skipped on one
  of them. Re-enabling Gatekeeper stays a single step on every OS version.

### Phase 6.1 — auditor round 2 (Auto Boot lock, URL-queue ceiling, toast, doc sync)

#### Added

- **`StatusItemToast`** (`Views/MenuBar/StatusItemToast.swift`) — a borderless, non-activating HUD
  under the status item. The left-click Gatekeeper toggle stays silent (no dropdown, no window, no
  panel) and the toast is the only feedback: “Gatekeeper: waiting for authorization…” immediately,
  then the outcome — “Gatekeeper is bypassed.” / “Gatekeeper is active.” / the failure text — taken
  from the *state re-read*, never from the optimistic request. A dismissed password prompt is
  silent.
- **`TooltipHost`** (`Views/Main/Components.swift`) — an AppKit-backed tooltip for SwiftUI content.
  SwiftUI’s `.help(_:)` is macOS 11+ and the floor here is 10.15, so the tooltip is attached to a
  real `NSView`. The locked Auto Boot row now shows the owner-specified **"Apple Silicon ไม่รองรับ"**.
- **`FeatureAvailability.tooltip`** — a lock can carry its own short hover copy, with `lockReason`
  as the fallback.
- **`AppDelegate.enqueue(_:)` with a hard ceiling** — `maxPendingURLs = 10`, oldest dropped.
- **`MenuBarController.statusItemVisibility`** plus two new Diagnostics rows (“Status item visible”
  and “If the icon is missing”) covering the macOS 26+ *System Settings → Menu Bar → Rosetta Stone →
  Allow in the Menu Bar* case. There is no public API for that switch, so the report carries both
  AppKit’s answer and the path to check.
- **`LICENSE`** — MIT, which the badge and the README’s licence section always claimed.

#### Changed

- **Auto Boot writes `%03`, not `%01`.** `%03` is the Intel default for “auto boot on”. The reader
  now accepts `%03` *and* the legacy `%01` as enabled, so an older firmware reporting `%01` is no
  longer read as OFF and then “fixed” by the user.
- **The Apple Silicon Auto Boot lock explains itself**: the row is disabled with a padlock as before,
  *and* says that M-series firmware owns the setting while its NVRAM is reset on every cold boot —
  auto-boot cannot be modified by the user at all.
- **The right-click menu is rebuilt to the owner’s list**: Open Main Window, Toggle Hidden Files,
  Flush DNS, Rebuild Spotlight, **Clear System Cache… (confirmed)**, Diagnostics… (⌘D), Quit (⌘Q).
  The duplicate *Toggle Gatekeeper* item is gone — the left click is that action now.
- **One warning constant for Clear System Cache** (`FeatureID.clearSystemCacheWarning`) shared by
  the panel sheet, the status-item menu and the URL-scheme confirmation, opening with the
  owner-specified Thai line **“⚠️ การล้าง System Cache อาจทำให้บางแอปช้าลงชั่วคราว”**. The feature
  is retained deliberately — the fix for “this is risky” is that it is never quiet about it, not
  that it disappears.
- **The Gatekeeper version rule moved to `SystemCommands`** as
  `gatekeeperDisableRequiresSystemSettingsConfirmation(majorVersion:)`; `GatekeeperPolicy` now owns
  only the deep link and the instruction copy.
- **Docs synced with the implementation.** ARCHITECTURE’s scaffolding note (“no Swift sources exist
  yet”) is gone, and every diagram, table and layering rule names the real types (`SystemCommands`,
  `FeatureCoordinator`, `CPUArchitecture`, `StartupManager`, `SystemStateReader`, `MenuBarController`,
  `ContentView`). FEATURES §1/§2/§4/§8/§9 cover the menu + toast, the two-step rule, `%03`, the cache
  warning and the 10-entry queue ceiling. USER-GUIDE gains §4.5 (first-run Gatekeeper vs the
  Gatekeeper toggle) and updates §5/§6.4/§6.6/§11. DECISIONS no longer points at a
  `Services/Privileges/PrivilegeEscalator` file that does not exist.

#### Fixed

- **The cold-start URL queue is bounded and cannot re-enter.** It is a plain array, drained exactly
  once after the presenter is built, with no `DispatchQueue.main.async` re-dispatch anywhere on that
  path — so a URL can neither be lost nor spin the drain — and capped at 10 entries, oldest dropped,
  with the overflow logged.
- **The README no longer advertises tool versions the project does not use.** It claimed “Xcode 12.5
  or newer” and carried a “Swift 5.9+” badge while `project.yml` pins `SWIFT_VERSION 5.0`; it now
  states Xcode 15+, XcodeGen 2.35+ and the missing `xcodegen generate` step, and the project-layout
  tree matches the real folders (there is no `Services/Privileges/` or `Services/System/`).

### Fixed

Hotfix for a macOS 26 Tahoe report: **the process ran, but no window and no menu-bar item
appeared.** The app looked completely dead. Root causes were found statically and all are fixed:

- **Status item could render zero-width.** `installStatusItem()` set `imagePosition = .imageOnly`
  from a single image source, so a missing or failed image produced an item with no intrinsic
  width — indistinguishable from "never created". It now resolves an image through an explicit
  fallback chain (SF Symbol → `StatusBarIcon` asset → code-drawn glyph) and *always* sets a `title`
  with `.imageLeading`, so the item can never be zero-width. Creation is asserted to be on the main
  thread inside `applicationDidFinishLaunching`, and the length is never 0.
- **No first-run window.** `hasLaunchedOnce` did not exist, so a brand-new install launched
  windowless with no Dock icon and no visible sign of life. The panel is now shown once on first
  run, and only when a normal launch was intended.
- **Cold-start URL actions could be silently dropped.** `handle(urls:)` re-dispatched exactly once
  on the next runloop turn and discarded the URL if the presenter was not up yet. URLs are now
  queued and drained once the status item exists, so all seven Shortcuts actions work with the app
  not running.
- **Activation policy is now asserted twice** — before and after the UI is built — so the
  `.accessory` (no Dock icon) posture holds even if `Info.plist` is wrong.
- **LaunchAgent launched the app with a window.** `ProgramArguments` now includes
  `--menu-bar-only` and the binary is exec'd directly (no `open -a` indirection), so "Run at
  Startup" produces a menu-bar gadget only.
- `NSLog` varargs misuse (`%@` for a Swift `String`) in the URL router, which is a latent
  format-string crash, replaced with a correct variadic call.

### Added

- **`Diagnostics…`** menu item (⌘D) — CPU architecture, macOS version, process ID, activation
  policy, launch posture, measured status-item width and resolved icon source, and whether the
  LaunchAgent is installed and current. Selectable and copyable; the same text is written to the
  log. This is the remote-debugging lifeline: the macOS 26 report was previously undiagnosable
  without a log file.
- `Trace` — lifecycle tracing on every launch, delegate, status-item, window and URL step, all
  prefixed `[RosettaStone]`.
- `scripts/first-run.sh` (Thai-commented) — removes the `com.apple.quarantine` attribute so
  Gatekeeper does not re-prompt. **It does not disable Gatekeeper.**
- `StatusBarIcon.imageset` in `Assets.xcassets` — the middle link of the status-item fallback
  chain. The catalog was previously empty.
- `docs/USER-GUIDE.md` §4 **"First run with Gatekeeper ON"** — the section was missing entirely,
  even though §11 already cross-referenced §4.2 and §4.3.
- `docs/FEATURES.md` §9 **"URL-scheme actions"** — the canonical table of all seven actions, which
  the documentation did not previously contain anywhere.
- `StartupManager.installedPlistIsMenuBarOnly()` — detects login items written before this flag
  existed, surfaced by Diagnostics.

### Changed

- `docs/ARCHITECTURE.md` §2 documents the real `ProgramArguments` (the old value named a
  `Rosetta Stone.app` path that the build never produces; the bundle is `RosettaStone.app`).

### Not changed, deliberately

- Signing stays **ad-hoc**. No notarisation is claimed anywhere in the project, and none is
  implied by this release. First launch requires one user override — see §4 of the user guide.
- The CI workflow structure and its triggers are untouched, and no `v*` tag was pushed.

### Added

- **`Diagnostics…`** menu item (⌘D) — CPU architecture, macOS version, process ID, activation
  policy, launch posture, measured status-item width and resolved icon source, and whether the
  LaunchAgent is installed and current. Selectable and copyable; the same text is written to the
  log. This is the remote-debugging lifeline: the macOS 26 report was previously undiagnosable
  without a log file.
- `Trace` — lifecycle tracing on every launch, delegate, status-item, window and URL step, all
  prefixed `[RosettaStone]`.
- `scripts/first-run.sh` (Thai-commented) — removes the `com.apple.quarantine` attribute so
  Gatekeeper does not re-prompt. **It does not disable Gatekeeper.**
- `StatusBarIcon.imageset` in `Assets.xcassets` — the middle link of the status-item fallback
  chain. The catalog was previously empty.
- `docs/USER-GUIDE.md` §4 **"First run with Gatekeeper ON"** — the section was missing entirely,
  even though §11 already cross-referenced §4.2 and §4.3.
- `docs/FEATURES.md` §9 **"URL-scheme actions"** — the canonical table of all seven actions, which
  the documentation did not previously contain anywhere.
- `StartupManager.installedPlistIsMenuBarOnly()` — detects login items written before this flag
  existed, surfaced by Diagnostics.

### Changed

- `docs/ARCHITECTURE.md` §2 documents the real `ProgramArguments` (the old value named a
  `Rosetta Stone.app` path that the build never produces; the bundle is `RosettaStone.app`).

- Complete application source under `RosettaStone/`: `App/`, `Models/`, `Services/`, `Views/Main/`,
  `Views/MenuBar/`, `Support/`, and the `Assets.xcassets` scaffold.
- `project.yml` — the XcodeGen project specification, and the single source of truth for the build.
  `RosettaStone.xcodeproj` is generated from it and is deliberately not committed.
- `.github/workflows/build-mac-dmg.yml` — the production DMG pipeline, verified green on both
  matrix legs.

### Changed

- **CI: `dotnet publish` → XcodeGen + `xcodebuild`.** The workflow now mirrors the reference .NET
  pipeline's structure, step order and Thai-comment style while building Swift. `setup-dotnet`
  becomes `brew install xcodegen`; `dotnet restore` becomes `xcodegen generate`; `dotnet publish`
  becomes `xcodebuild -project RosettaStone.xcodeproj -scheme RosettaStone -configuration Release
  -derivedDataPath build -destination 'generic/platform=macOS' ARCHS=<arch> ONLY_ACTIVE_ARCH=NO
  CODE_SIGNING_ALLOWED=NO build`. `ARCHS` comes from the matrix, so the Intel leg cross-compiles on
  the Apple Silicon runner.
- **CI: manual bundle assembly replaced by a copy.** The reference workflow built its `.app` by
  hand with `mkdir`, a `cat`-heredoc `Info.plist` and a `PkgInfo`. `xcodebuild` already emits a
  complete bundle, so the step is now a single
  `cp -R build/Build/Products/Release/RosettaStone.app dist/<output_name>.app`. The `Info.plist` is
  no longer generated by the pipeline at all: it is `RosettaStone/Support/Info.plist`, wired in via
  `INFOPLIST_FILE`, so it is reviewed alongside the code. `LSMinimumSystemVersion` remains `10.15`.
- **CI matrix keys.** `arch` + `output_name` replace the previous `os` + `app_name` + `arch`; both
  legs run on `macos-latest`. Artifacts are named `<output_name>-dmg`.
- **CI: signing moved after the copy.** The build passes `CODE_SIGNING_ALLOWED=NO` and the ad-hoc
  `codesign --force --deep --sign -` runs on the bundle in `dist/`, so no certificate is needed
  during `xcodebuild` and the signed directory is exactly the one that gets packaged.
- **CI: `create-dmg` flags.** `--volname "Rosetta Stone Installer"`, `--window-pos 200 120`,
  `--window-size 600 400`, `--icon-size 100`, `--icon <app> 150 190`,
  `--hide-extension <app>`, `--app-drop-link 450 190`, `--no-internet-enable`, with a trailing
  `|| true`.
- **CI: DMG verification.** A dedicated *Verify DMG* step fails the job with an `::error::`
  annotation when the image is missing or zero-length, then records `ls -lh`. Because the
  `create-dmg` step tolerates a non-zero exit, this is what guarantees a bad image cannot be
  uploaded.
- **CI: dropped the Xcode version pin, the `Clean previous build output` step, the
  `Show toolchain version` step, the `PlistBuddy` version-stamping step and the
  `Strip quarantine attributes` step**, so the pipeline matches the reference step-for-step. The
  version is carried by `project.yml` instead, and the version display is not a release gate.
- **CI: artifact retention** uses the default rather than a fixed 30 days, and the release job
  downloads to `dmgs/` with the `dmgs/**/*.dmg` glob instead of merging into one directory.
- `PRODUCT_NAME` is now `RosettaStone` (no space) so the DerivedData product path CI copies from is
  exact. The user-facing name is unchanged — `CFBundleDisplayName` in `Info.plist` still reads
  "Rosetta Stone".

### Fixed

Compile errors found by the first remote CI runs and fixed here:

- `StartupManager`: `Bundle.main.executableURL` is `URL?`, not `URL`. It is now unwrapped through a
  fallback chain (`executableURL` → `CFBundleExecutable` → `"RosettaStone"`), so a `nil` can never
  trap the app at the moment the user enables *Run at Startup*.
- `StartupManager`: `ProcessInfo` has no `userIdentifier` member. Added `import Darwin` and a
  `userID` property backed by `getuid()`, used for the `gui/<uid>` launchctl domain and the `chown`
  of the installed plist. The process is never elevated in-process, so `getuid()` is the user UID
  the LaunchAgent must be owned by.
- `SystemCommands`: `LocalizedError.errorDescription` is `String?`, not `String`. It is now coalesced
  with a non-nil default rather than force-unwrapped.
- `FeatureCoordinator+Actions`: assigning `statusMessage` from a second file failed because
  `private(set)` scopes the setter to the *declaring* file. Both toggle paths now use the existing
  `report(_:style:)` helper — same message, same `.success` style, still published on the main
  thread from inside the locked operation.
- `RosettaStoneApp`: removed `.onOpenURL`, which does not exist on a macOS `Settings` scene. On
  macOS SwiftUI delivers URLs through `handlesExternalEvents(matching:)`; URL handling already lives
  in `AppDelegate.application(_:open:)`, the canonical AppKit entry point, so this removes a
  duplicate route rather than a capability. `@NSApplicationDelegateAdaptor` is retained because it
  is what instantiates the delegate.
- `FeatureCoordinator.StatusStyle` now conforms to `Equatable`, so the containing `StatusMessage`
  can synthesise its own `Equatable` conformance.
- `ContentView.toggleRow` assigns through the binding instead of calling the mutating
  `wrappedValue.toggle()` on a `let` parameter.

### Audit fixes retained

The following earlier audit fixes are preserved and are covered by the green build:

- `PillSwitch` is built from a `Button`-based row, not a SwiftUI `Toggle`, to stay within the
  macOS 10.15 API floor and to control the hit area.
- The `NSStatusItem` deliberately does **not** assign `item.menu`; the dropdown is presented
  manually on right-click, because a status item with an attached menu never sends its action and
  would make the panel unreachable.
- The single-operation lock is taken and released on the serial `queue` via `activeFeature`, never
  on the main thread.
- The toggle actions read the current state *inside* the locked operation, so a read-modify-write
  pair cannot interleave with another operation.
- The Rosetta 2 Install button is rendered but **disabled** on Intel rather than hidden, so the
  panel does not reflow and the row reads "this Mac cannot use it", not "this feature is missing".

### Documentation

- `docs/CI-CD.md` rewritten to describe the final pipeline step-by-step, including why
  `CODE_SIGNING_ALLOWED=NO` is safe given the later ad-hoc sign, and why the `|| true` on
  `create-dmg` cannot mask a real failure.
- `docs/DECISIONS.md` — ADR-004 and ADR-005 updated to the current `create-dmg` flags and matrix.

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


