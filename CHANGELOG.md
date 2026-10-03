# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

The first working build. Application code, the XcodeGen project specification and the CI
pipeline now exist and both matrix legs build green on GitHub Actions.

### Phase 9 — deferred queue, single-auth batching, app icon, credits

**Clicking a switch no longer runs a command.** The panel became a staging area: every row records
an intent, and two master buttons — **❌ ยกเลิก** and **✅ ตกลง** (⌘↩) — commit or discard the
whole set. Committing raises **one** password dialog for the entire queue.

Before this, switching on Gatekeeper, Hidden Files and Auto Boot in one sitting produced **three**
Authorization dialogs: the same password typed three times, each prompt stealing focus from the
panel. That was the problem being solved.

#### Added

- **The deferred queue.** `@State pendingChanges: [FeatureID: PendingChange]` in `ContentView`
  holds staged intents; `stageToggle` / `stageAction` record them and `applyPendingChanges` /
  `cancelPendingChanges` commit or discard them. The switch renders the **staged** value, because a
  panel that appears to ignore your click reads as a bug ([ADR-009](docs/DECISIONS.md#adr-009)).
- **An orange ● pending dot** beside any row title holding a staged change (`PendingDot`,
  `Theme.pending`). It is defined as `pending ≠ actual`, so toggling a switch and toggling it
  straight back leaves no dot behind — a dot for a change that does not exist would be a lie.
- **`ApplyBar`** — the two master buttons, disabled while the queue is empty so the panel teaches
  the rule by refusing to apply nothing. Apply carries ⌘↩ on macOS 11+, via
  `ConditionalCommandReturnShortcut`. **Both** `keyboardShortcut` overloads are macOS 11+ in this
  SDK, so the 10.15 branch deliberately applies *no* keyboard shortcut rather than reaching for one
  that does not exist; the button itself is fully usable by click on every supported version.
- **`SystemCommands.runBatched(_:)`** — the single-auth engine. It splits commands by
  `requiresAdmin`, concatenates every privileged command into **one** shell script inside a single
  `do shell script … with administrator privileges`, and derives per-command outcomes from stdout
  markers rather than the exit code.
- **`FeatureCoordinator.applyBatch(_:)`** — commits a queue under the **same** single-operation
  lock every other write uses, so a batch and a menu-bar toggle can never each believe they own the
  machine and raise two dialogs at once.
- **`BatchReportSheet`** — a per-item ✅/❌ dialog raised only when something actually failed. It
  lists *every* row, not just the failures, so the successes are visibly confirmed too.
- **The `สำเร็จทั้งหมด` banner** on a fully successful batch, plus a count on the Apply button.
- **`RosettaStone/Support/AppIcon.appiconset/`** — the ten macOS icon sizes, with the
  `ASSETCATALOG_COMPILER_APPICON_NAME` / `CFBundleIconFile` wiring.
- **`scripts/generate-icons.sh`** — generates all ten sizes from the 1024×1024 master with
  ImageMagick, then verifies that every file the committed `Contents.json` references exists.
  Preflight fails loudly and specifically for each of the three ways to be misconfigured.
- **App icon credits** in `README.md` §Credits and `Info.plist`, naming Abshifflett and
  [CC BY-SA 3.0](https://creativecommons.org/licenses/by-sa/3.0)
  ([ADR-010](docs/DECISIONS.md#adr-010)).

#### Changed

- **Per-command results come from markers, not the exit code.** A multi-command script's status is
  always the status of its last command, so 7/7 and 2/7 would both report `0`. Each command is
  wrapped as `if ( cmd ) >/dev/null 2>&1 ; then echo 'RS_OK:<feature>' ; else echo 'RS_FAIL:<feature>' ; fi`.
- **Markers are matched exactly, never by prefix.** `RS_OK:install-rosetta-extra` must never
  satisfy the `install-rosetta` row. `FeatureCommand.marker` is derived from `FeatureID.rawValue`
  so a command cannot be reported under a marker that does not match its row.
- **Silence is failure.** A command that prints no marker is reported as failed — the existing
  "never trust the exit code" rule, applied to an exit code that is always `0`.
- **No `set -e`, and no `&&`/`||` chains.** `set -e` would abort the batch on the first failure; in
  an `&&` chain a command whose last statement fails can emit *both* markers. Commands are joined
  with `;` inside their own `if/then/else`, so one failure never aborts the rest.
- **`killall Finder` runs once per batch**, not once per row, and only if the hidden-files write
  actually succeeded. It moved from the command body to `FeatureCommand.batchPostStep`.
- **Auto Boot is re-checked at apply time.** A change staged on a row that later became
  unavailable is refused rather than written to firmware.
- **A batch inherits its slowest member's timeout**, so a queued Rosetta 2 install is not cut off
  at the 30 s default.
- **Cancellation is silent, aborts the batch, and keeps the queue.** Dismissing the Authorization
  dialog reports **every** row as cancelled — privileged *and* unprivileged — and the
  unprivileged half is then **not run**. Running the LaunchAgent write while Gatekeeper silently
  did not change would be exactly the half-applied state the queue exists to prevent. The queue is
  left intact, so ✅ can simply be pressed again.
- **The macOS 15+ Gatekeeper follow-up now runs after a batch too**, and only when `spctl`
  succeeded. Opening System Settings after a failed or cancelled command would contradict the
  message the user is looking at.
- **Confirmations moved to stage time.** The Auto Boot NVRAM warning, the Rosetta 2
  "several minutes" warning and the Clear System Cache warning are all shown *before* the password
  prompt now, rather than between it and the command.
- **There is one command table.** `FeatureCoordinator.command(for:pending:)` is now the only place
  that turns a feature plus a desired value into a command, and the immediate paths
  (`setRunAtStartup`, `toggleGatekeeper`, `flushDNS`, …) route through `runImmediately(_:pending:)`.
  The queued route and the shortcuts therefore execute byte-identical commands and cannot drift.
  `FeatureCoordinator.Tool` became internal so both can share the same binary paths.
- **`activeFeature` became `ActiveOperation`** (`.feature(_)` / `.batch`), because the invariant is
  *one privileged thing at a time*, not *one row at a time*. `isBusy` now also covers
  `isApplyingBatch`, which keeps the menu bar from firing a shortcut beside a live dialog.
- **The panel is 60 pt taller** (`panelHeight` 540 → 600). The extra height is absorbed by the
  existing `Spacer`s, so no row was shrunk or removed.

#### Security / robustness

- **Pending state is view-local and never read by a service.** `ContentView` owns
  `pendingChanges`; a service receives an already-built `[FeatureCommand]` and never learns a queue
  exists. This is what keeps "what the user wants" from being mistaken for "what the system is".
- **`PendingChange` is an enum, not `Any`.** A `[FeatureID: Any]` queue forces every read back
  through a cast, and a mis-cast silently degrades to "no pending change" — the user stages a
  change, presses Apply, and nothing happens.
- **Batch output is redirected** (`>/dev/null 2>&1`) so `spctl`, `nvram` and `rm` chatter cannot
  corrupt marker parsing, and the batch script is built entirely from constants — no user input,
  URL parameter or runtime-discovered name is ever interpolated.
- **The appiconset is excluded from the `RosettaStone` sources glob and added under `resources:`.**
  The glob already matches `Support/AppIcon.appiconset`, so listing it in both places would add the
  same file to the target twice and fail the XcodeGen run.
- **Every resize in `generate-icons.sh` passes `-background none -alpha set`.** Without it, ImageMagick
  flattens transparency against black and leaves a dark box around the glyph in every size — a
  defect that only shows up on a light wallpaper.

#### Not changed, deliberately

- **The menu-bar left-click, the right-click menu and the `rosettastone://` URL actions still run
  immediately.** They are shortcuts, not batch configuration. Deferring them would add a step for no
  benefit, and a queued URL action is worse than useless — it is a *silently dropped* action,
  because the Shortcut has no way to press Apply.
- **A pending change is not persisted across launches.** The window is retained, and a half-configured
  Mac is not worth restoring into a fresh session.
- **Clear System Cache still requires its confirmation even when URL-driven**, and the warning copy
  is still one constant shared by the panel sheet, the status-item menu and the URL scheme.
- **The build does not depend on ImageMagick.** The generated PNGs are committed; the script is a
  maintenance tool that only runs when the master icon changes.

#### Documentation

- `docs/FEATURES.md` — new **§10 The deferred queue**, with the actual-vs-pending table, the master
  buttons, a Mermaid batch-execution flowchart, the four batch invariants, the per-feature queue
  matrix, the three bypass routes and the batch feedback table. **Queued?** added to the summary
  matrix, and a queue note on each of the eight feature sections.
- `docs/ARCHITECTURE.md` — **§4 Single-auth batching** with the generated script and a Mermaid
  sequence diagram of the whole flow; §6 gains *Two layers of state: actual vs pending*, *The one
  command table* and *App icon pipeline*; two new layering rules.
- `docs/USER-GUIDE.md` — new **§12 Using the Apply / Cancel buttons** and **§13 Understanding the
  orange ●**, plus §3.1 on the app icon and five new troubleshooting entries. "Further reading"
  renumbered to §14.
- `docs/DECISIONS.md` — **ADR-009** (deferred queue) and **ADR-010** (CC BY-SA 3.0 icon with
  attribution), each with context, decision, rationale, consequences and alternatives.

#### Verification

- **41 assertions** over `batchScript(for:)` and `parseBatchMarkers(_:commands:)`, run off-macOS
  from a bare `swiftc`: one marker pair per command, output suppressed, commands joined so one
  failure cannot abort the batch, no `set -e`, no `&&` chain, inline work contributing no shell,
  per-command outcomes, **silence treated as failure**, **prefix look-alikes rejected**,
  **noisy stdout not fabricating successes**, CRLF and padded lines trimmed, result ordering
  preserved, and `BatchReport` distinguishing failure from cancellation.
- The Foundation-only model and service layer type-checks clean; the full 23-file tree
  syntax-checks clean. Remaining `typecheck` errors are pre-existing macOS-only APIs
  (`sysctlbyname`, `import Darwin`) that cannot resolve off-macOS.

### Phase 8 — one bundle name; the arch suffix only on DMGs and artifacts

**Installing Rosetta Stone put a chip name in the user's Applications folder.** CI staged each matrix
leg as `dist/<output_name>.app`, so dragging the app out of the DMG produced
`/Applications/RosettaStone-Intel.app` on one Mac and `/Applications/RosettaStone-AppleSilicon.app`
on another. The app is the same app; only the download should differ by architecture. From now on the
bundle is **always `RosettaStone.app`** and the suffix lives **only** in the `.dmg` filename and the
artifact name.

This is a naming-only phase. The Intel crash (exit 132 / SIGILL at `AppDelegate.init()`) was already
fixed by `override init()` plus the CI smoke test; nothing in this phase touches that.

#### Changed

- **The bundle is never renamed.** Each step that touches it defines `BUNDLE="dist/RosettaStone.app"`
  once and uses that — the `cp -R` in *Collect app bundle*, `codesign` in *Ad-hoc codesign*, the
  smoke-test binary path, and the `create-dmg` source. `matrix.output_name` is no longer a
  consumer of anything except the DMG output path and the artifact name, which is what it was
  always for.
- **`create-dmg` no longer needs `cd dist`.** The source is the architecture-neutral
  `dist/RosettaStone.app` and the output is `dist/${{ matrix.output_name }}.dmg`, so both paths are
  stated in full and the working-directory dance is gone. `--icon` and `--hide-extension` now
  reference `"RosettaStone.app"`.
- **`scripts/first-run.sh` targets one canonical path**, `/Applications/RosettaStone.app`, rather
  than treating names as interchangeable. It now also checks for legacy
  `RosettaStone-Intel.app` / `RosettaStone-AppleSilicon.app` in `/Applications` and prints a Thai
  hint asking the user to delete them.
- Docs: README install section, `docs/USER-GUIDE.md` (§3 install, §4.3 first-run), `docs/CI-CD.md`
  (step list, step 5/7/9/10 write-ups, naming table, local reproduction) and the ADR-004
  `create-dmg` command block.

#### Added

- **A DMG content assertion in the *Verify DMG* step.** The old check only proved the image existed
  and was non-empty. It now mounts the DMG with `hdiutil attach -nobrowse -readonly`, asserts
  there is **exactly one** `.app` at the volume root and that it is named `RosettaStone.app`, prints
  the volume listing as evidence, and detaches. Any other state fails the job with `::error::`.
  This is what makes the naming rule enforceable rather than aspirational: a future change that
  reintroduces a rename now breaks the build instead of shipping the wrong app name to users.
- `find … -maxdepth 1` keeps the assertion from counting nested bundles such as
  `Contents/…/Helper.app`, and an `EXIT` trap guarantees `hdiutil detach` runs even when the
  assertion fails, so no image is left mounted on the runner.

#### Not changed, deliberately

- **No new runtime code.** An audit of every runtime path that could name the bundle —
  `StartupManager.currentExecutablePath` (`Bundle.main.bundlePath` + `executableURL`),
  `DiagnosticsPanel` (*Bundle path* field), `URLActionRouter`, `GatekeeperPolicy` — found **zero**
  hardcoded bundle names. Everything already derives from `Bundle.main`, so a single-name rule
  needs no app change and cannot desynchronise from CI.
- **`matrix.output_name` keeps its values**, and the DMG filenames and artifact names are
  unchanged: `RosettaStone-AppleSilicon.dmg` / `RosettaStone-Intel.dmg`, uploaded as
  `…-dmg`. The Releases page still tells the two downloads apart, which is the whole point of the
  suffix.
- **Triggers and the `release` job are untouched**, and no `v*` tag was pushed.
- **Deployment target stays 10.15**; no Swift build settings changed.
- **`first-run.sh` still does not delete anything.** Removing an app from `/Applications` is a user
  decision; the script prints the hint and the exact command.

### Phase 7.2 — MacProfile wiring, committed tests, CI gate

**Auto Boot was gated on `uname -m` alone, which let every Intel desktop through.** An iMac, Mac
mini, Mac Studio and Mac Pro all report `x86_64`, so all four were offered a live toggle for a
setting that does nothing there — the feature is about opening a lid, and on Intel desktop firmware
`nvram AutoBoot` is absent or inert. Auto Boot is now gated on the **model** as well as the chip.

#### Added

- **`MacProfile`** (`Services/MacProfile.swift`) — the model name, the form factor derived from it
  (`MacFormFactor`: `.laptop` / `.desktop` / `.unknown`) and the already-detected
  `CPUArchitecture`. Detected once per process from `system_profiler SPHardwareDataType`, falling
  back to `sysctl -n hw.model`. Both sources are read-only and unprivileged, so opening the window
  still costs nothing. See [ADR-008](docs/DECISIONS.md#adr-008).
- **`tests/MacProfileTests.swift`** — **39 assertions**, self-contained with stubs and runnable
  **off-macOS** from a bare `swiftc`. Committed rather than kept as a scratch file because this gate
  is the one place in the app where a wrong answer writes permanent firmware settings:
  ```bash
  swiftc -swift-version 5 -o macprofile-tests tests/MacProfileTests.swift
  ./macprofile-tests
  ```
- **CI `test` job** — runs the harness on `ubuntu-latest` (Swift is preinstalled, so no
  `setup-swift` action) and **gates the build** via `build.needs: test`. A regression in the Auto
  Boot gate now stops the pipeline instead of shipping a DMG.
- **Diagnostics fields** — *Model name*, *Form factor*, *Auto Boot supported* and *Auto Boot lock
  reason*, so a greyed-out row is verifiable from a copied report without a second round-trip.
- **Panel header** now shows the form factor as well as the architecture (`macOS 15.4 · Intel ·
  Laptop`), because an “Intel” caption alone is misleading on a Mac mini, whose row is locked.

#### Changed

- **`FeatureID.availability(on:)` takes a `MacProfile`**, not a bare `CPUArchitecture`. Auto Boot
  availability is `profile.supportsAutoBoot`; the row subtitle **and** the hover tooltip both carry
  `profile.autoBootDisabledReason`, so a greyed row always explains itself.
- **`CPUArchitecture.supportsAutoBoot` removed.** There is now exactly one Auto Boot rule in the
  codebase, with the rationale recorded on `supportsRosettaInstall` so it is not re-added.
- **`FeatureCoordinator` exposes `MacProfile.current`** (`init(profile:)` is injectable) and keeps
  `architecture` as a derived accessor for the header, the menu and Diagnostics.
- Rosetta 2 remains purely architectural (`profile.cpuArchitecture`) — it does not care about a lid.

#### Fixed

- **Intel desktops no longer offer a dead Auto Boot toggle.** The gate requires
  `formFactor == .laptop` **and** `cpuArchitecture == .x86_64`; neither condition is sufficient alone.
- **Every locked Auto Boot row carries a reason.** Three are possible, and the app reports the one
  that matches the machine: `Desktop Mac ไม่มีฝาเปิด-ปิด`, `Apple Silicon reset NVRAM ทุกครั้งที่ cold boot`,
  or the English fail-safe string for an unrecognised model. An `.unknown` model **locks** the row
  rather than guessing, matching the rule ADR-007 set for an unrecognised architecture.

#### Security / robustness

- **The write path keeps its own Intel-only guard.** `FeatureCoordinator.setAutoBoot` checks
  `x86_64` as a literal rather than delegating to the profile, so the invariant holds even if the
  profile is ever wrong — the write path is reachable without touching the UI.

#### Documentation

- `docs/FEATURES.md` §4 — 5-row availability matrix (Intel laptop ✅ / Apple Silicon laptop ❌ NVRAM
  / Intel desktop ❌ no lid / Apple Silicon desktop ❌ both / unknown) and rewritten edge cases.
- `docs/ARCHITECTURE.md` §5 is now “Hardware detection”: 5.1 `uname`, 5.2 the `MacProfile` flow with
  a `system_profiler → hw.model` fallback diagram, 5.3 the combined detection flow, 5.4 method
  alternatives. `MacProfile` added to the §1 services diagram and the §6 component map.
- `docs/DECISIONS.md` — **ADR-008** records the no-grep parsing choice, the `hw.model` blind spot on
  M-series, the `.unknown` fail-safe, and the committed harness location.
- `docs/USER-GUIDE.md` — the **“ทำไมปุ่ม Auto Boot ถึงจาง?”** troubleshooting entry with all three
  reasons, plus §5 lock icon, §6.4 and §11.
- `docs/CI-CD.md` — the new `test` job, its runner choice and gating rationale; `release` is now
  `needs: [test, build]`.
- `README.md` — Auto Boot availability is **“Intel MacBook only”**, plus the test command.

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


