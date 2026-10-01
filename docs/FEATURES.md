# Features Specification

Source of truth for every Rosetta Stone capability. Each section below states the purpose, the
exact shell command executed, whether administrator rights are required, the availability matrix,
the UI control type, and the edge cases the implementation must handle.

Notation used throughout this document:

- **(admin)** — the command is executed with root privileges via
  `osascript -e 'do shell script "..." with administrator privileges'`.
- Plain command blocks (no marker) run as the logged-in user with no elevation.

---

## Summary matrix

| # | Feature | UI control | Admin? | Intel x64 | Apple Silicon arm64 |
|---|---------|------------|--------|-----------|---------------------|
| 1 | Run at Startup | Toggle | **Yes** (admin) | ✅ Available | ✅ Available |
| 2 | Gatekeeper | Toggle | **Yes** (admin) | ✅ Available | ✅ Available |
| 3 | Hidden Files | Toggle (ON = show) | No | ✅ Available | ✅ Available |
| 4 | Auto Boot | Toggle | **Yes** (admin) | ✅ Available | ⛔ Greyed + lock icon |
| 5 | Rosetta 2 | Install button | **Yes** (admin) | ⛔ Greyed | ✅ Available |
| 6 | Spotlight Rebuild | Button | **Yes** (admin) | ✅ Available | ✅ Available |
| 7 | DNS Flush | Button | **Yes** (admin) | ✅ Available | ✅ Available |
| 8 | Clear System Cache | Button | **Yes** (admin) | ✅ Available | ✅ Available |

### Privilege matrix

| # | Feature | Writes to | Elevation prompt | Reversible via app? |
|---|---------|-----------|------------------|--------------------|
| 1 | Run at Startup | `~/Library/LaunchAgents/` | Yes | Yes — toggle off |
| 2 | Gatekeeper | System policy daemon | Yes | Yes — toggle on |
| 3 | Hidden Files | `com.apple.finder` prefs | No | Yes — toggle back |
| 4 | Auto Boot | NVRAM | Yes | Yes — toggle on (Intel only) |
| 5 | Rosetta 2 | `/usr/libexec/oah/` | Yes | No — uninstall is manual |
| 6 | Spotlight Rebuild | Spotlight index | Yes | N/A — rebuild is idempotent |
| 7 | DNS Flush | `dscacheutil` / `mDNSResponder` | Yes | N/A — flush is idempotent |
| 8 | Clear System Cache | `/Library/Caches/` | Yes | No — caches regenerate over time |

---

## 1. Run at Startup

### Purpose
Install or remove a per-user `LaunchAgent` so Rosetta Stone is automatically relaunched at every
login — and, in doing so, **choose the app's mode**. This toggle is the app's posture switch:

| Toggle | Mode | Launch | Window | Dock icon | Menu-bar icon | URL actions |
|--------|------|--------|--------|-----------|---------------|-------------|
| OFF (default, first install) | **A — normal app** | panel shown | visible | **yes** | none | refused |
| ON | **B — menu-bar gadget** | hidden | none at launch | **no** (`LSUIElement`) | always visible | all seven work |

The switch takes effect **live**, in the running process: turning it ON installs the login item,
installs the menu-bar icon and drops the Dock icon; turning it OFF deletes the login item,
removes the menu-bar icon in-process and restores the normal app (Dock icon + window). No
relaunch is involved in either direction.

### Mode B at a glance

- **Left-click the menu-bar icon toggles Gatekeeper directly** — no dropdown, no window. The
  macOS password prompt appears, and a **toast** under the icon reports the outcome
  (`StatusItemToast`: “Gatekeeper is bypassed.” / “Gatekeeper is active.” / the failure text).
  A dismissed prompt is silent, and hovering the icon shows the same state in its tooltip.
- **Right-click (or Control-click)** opens the full menu: Open Main Window, Toggle Hidden
  Files, Flush DNS, Rebuild Spotlight, Clear System Cache… (confirmed), Diagnostics… (⌘D),
  Quit (⌘Q).
- The window is only ever shown on demand: the menu item, `rosettastone://open-app`, or a
  Launch Services / Dock activation.

### Exact command

Installation — writes a property list to the user's LaunchAgents directory **(admin)**:

```bash
# Managed internally as: write plist to a staging file, then (as root)
mkdir -p ~/Library/LaunchAgents
cp <staged plist> ~/Library/LaunchAgents/com.rosettastone.helper.plist
chown <uid> ~/Library/LaunchAgents/com.rosettastone.helper.plist
```

Removal **(admin)**:

```bash
rm -f ~/Library/LaunchAgents/com.rosettastone.helper.plist
```

**There is deliberately no `launchctl` step.** `launchctl bootstrap`/`load` would spawn a
*second* instance immediately (the job is `RunAtLoad`), and `launchctl bootout` during removal
would terminate the very process performing the removal. launchd loads every plist in
`~/Library/LaunchAgents` at the next login by itself, and the running process carries the live
mode switch — see `docs/ARCHITECTURE.md` §2.

The generated `com.rosettastone.helper.plist` runs the app's **absolute executable path**
directly (never `open -a`), passes `--menu-bar-only`, and sets `RunAtLoad = true`,
`ProcessType = Interactive` and `LimitLoadToSessionType = Aqua`.

### State readback
Toggle state = *does `~/Library/LaunchAgents/com.rosettastone.helper.plist` exist?*
No elevation is needed to **read** this; elevation is only required to create/remove.

The same read decides the **mode at launch**: plist exists → mode B (even for a manual
double-click in Finder), plist absent → mode A. The `--menu-bar-only` argument is an
additional, explicit signal used by the login launch.

### Availability

| Platform | Supported | Notes |
|----------|-----------|-------|
| macOS 10.15+ | ✅ | LaunchAgent plist semantics are unchanged across the whole range |
| Intel x64 | ✅ | |
| Apple Silicon arm64 | ✅ | Runs natively; no Rosetta required |

### Edge cases
- The plist path is per-user. Elevation is still used so the file is written outside a
  sandboxed / read-only context; if the process runs unelevated, the write falls back to the
  invoking user's home only.
- A **stale** plist may exist from a previous install at a different path — including one
  written by an older build without `--menu-bar-only`. The app must treat "file exists" as ON
  (and as mode B) even if `launchctl list` shows no loaded job, and offer a clean reinstall
  (off → on) to regenerate it. Diagnostics flags a plist without the flag as an older-build
  item.
- If the user drags the app to a different location after enabling, the plist's
  `ProgramArguments` path becomes stale. The UI must show a warning until the user re-toggles
  the switch (off → on) to regenerate it.
- Cancelling the authorization prompt for ON leaves the app in mode A, and for OFF leaves it in
  mode B. The mode follows the plist, and the plist only changes when the command actually
  runs — the toggle can never claim a posture the disk does not have.
- An already-loaded job from the current session is not unloaded by turning the toggle off. It
  stays loaded until logout but cannot restart the app (there is no `KeepAlive`), and it is not
  loaded at the next login because the file is gone.
- Quitting the app (⌘Q / Quit in the menu) leaves the login item in place: the icon returns at
  the next login, which is exactly what "Run at Startup" promises.

---

## 2. Gatekeeper

### Purpose
Toggle macOS Gatekeeper's *master switch* between enforcing and disabled. Useful when a
developer needs to run an unsigned or unnotarized tool (a Homebrew cask, an internal build, a
legacy installer) without Gatekeeper blocking it.

> ⚠️ This is a security-critical toggle. Turning it off removes one of the OS's main protections
> against running untrusted software.

### Exact command

Disable **(admin)** — one step on macOS 10.15 – 14, **two steps on macOS 15 and later**:

```bash
spctl --master-disable
```

Enable **(admin)** — one step on every version:

```bash
spctl --master-enable
```

### Disabling on macOS 15 Sequoia and later (Tahoe 26 / Golden Gate 27)

```swift
runCommand("spctl --master-disable")
openURL("x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
showAlert("กรุณาเลือก 'Anywhere' ใน System Settings เพื่อยืนยันการปิด Gatekeeper")
```

On macOS 15+ the CLI command alone no longer flips the **user-visible** switch: the user must
also choose **Anywhere** under System Settings → Privacy & Security → Security → “Allow
applications from”. The app therefore:

1. runs `spctl --master-disable` (admin) exactly as before,
2. opens System Settings at Privacy & Security, and
3. shows the confirmation alert with the instruction above.

The version rule lives in `SystemCommands.gatekeeperDisableRequiresSystemSettingsConfirmation(majorVersion:)`
(`majorVersion >= 15`), so one call covers Sequoia, Tahoe and Golden Gate. `GatekeeperPolicy` owns
the user-facing half: the deep link and the instruction text. Re-enabling never triggers the
second step.

| macOS | Disable procedure |
|-------|-------------------|
| 10.15 Catalina → 14 Sonoma | **1** — the CLI command is the whole job |
| 15 Sequoia → 27 Golden Gate | **2** — CLI command, then the user picks **Anywhere** in System Settings |

The app never tries to click “Anywhere” itself. System Settings is not scriptable for this
switch, and automating a security downgrade would be indistinguishable from malware.

### State readback
```bash
spctl --status
# "assessments enabled"  -> toggle OFF (Gatekeeper active)
# "assessments disabled" -> toggle ON  (Gatekeeper disabled)
```
`spctl --status` is readable **without** elevation.

### Availability

| Platform | Supported | Notes |
|----------|-----------|-------|
| macOS 10.15–12 | ✅ | One-step procedure |
| macOS 13–14 (Ventura / Sonoma) | ✅ | One-step; some policy-managed configurations reject the command — treat a non-zero exit as a failure and show the stderr |
| macOS 15 Sequoia → 27 Golden Gate | ✅ | **Two-step procedure** — see above |
| Intel x64 | ✅ | |
| Apple Silicon arm64 | ✅ | |

### Edge cases
- On **Apple Silicon**, Gatekeeper is stricter and some enterprise MDM configurations
  re-enable it immediately. The app must re-read `spctl --status` after the command completes
  and reflect reality rather than optimistically assuming success.
- On macOS 15+, between the command succeeding and the user choosing “Anywhere”, `spctl
  --status` can still report the old value. The app raises the confirmation alert as soon as
  the command succeeds and re-reads the state afterwards, so the toggle ends up reflecting
  the disk rather than the request.
- The switch, the right-click menu item, the **left-click direct toggle** and
  `rosettastone://toggle-gatekeeper` all funnel through one write path
  (`FeatureCoordinator.writeGatekeeper(bypassed:)`), so the two-step procedure cannot be
  skipped on one of them.
- If a corporate MDM profile manages the setting, the toggle will appear to snap back. Surface
  a hint that the setting is policy-managed.
- Never leave the app in a state where the user cannot find how to re-enable it: the
  documentation and the menu-bar menu must both offer the reverse action.

---

## 3. Hidden Files

### Purpose
Show or hide dotfiles (`.git`, `.env`, `.DS_Store`, …) in Finder. Conventionally the
pathologist's toggle — the single most-used hidden macOS setting.

**Toggle semantics: ON = hidden files are shown.** This is deliberately inverted relative to the
system default so the switch matches user intent rather than the underlying boolean.

### Exact command

Show hidden files (no elevation):

```bash
defaults write com.apple.finder AppleShowAllFiles YES
killall Finder
```

Hide hidden files (no elevation):

```bash
defaults write com.apple.finder AppleShowAllFiles NO
killall Finder
```

### State readback
```bash
defaults read com.apple.finder AppleShowAllFiles
# 1 -> ON (shown)
# 0 -> OFF (hidden)
# (no output) -> OFF
```
Readable **without** elevation. This is the only feature that never prompts for a password.

### Availability

| Platform | Supported | Notes |
|----------|-----------|-------|
| macOS 10.15+ | ✅ | |
| Intel x64 | ✅ | |
| Apple Silicon arm64 | ✅ | |

### Edge cases
- `killall Finder` terminates the Finder process; the Dock and desktop briefly disappear and
  relaunch. The app's own window is unaffected.
- The `AppleShowAllFiles` key is a **per-user, per-Finder** preference. Multiple Finder windows
  all update at once because the restart is global to the session.
- If the key has never been written, `defaults read` returns an error rather than `0`. Treat
  "key absent" as OFF, and treat a read failure as "unknown" rather than defaulting to ON.
- The app must not perform this write on app launch as a side effect of reading state.

---

## 4. Auto Boot

### Purpose
Control whether the Mac powers on automatically when the power is restored or the user presses
the power button. Encoded as an NVRAM variable `AutoBoot` using a **3-digit zero-padded binary
value** — the format firmware expects.

- `%00` = binary `000` = **disabled** (toggle OFF)
- `%03` = binary `011` = **enabled** (toggle ON) — the Intel default for "auto boot on"

> Note the deliberate divergence from the other features: here **ON = auto boot enabled**,
> matching the system default. Only Hidden Files uses inverted semantics.

### Exact command

Enable auto boot **(admin)**:

```bash
nvram AutoBoot=%03
```

Disable auto boot **(admin)**:

```bash
nvram AutoBoot=%00
```

### State readback
```bash
nvram AutoBoot
# AutoBoot    %03   -> toggle ON  (auto boot enabled)
# AutoBoot    %01   -> toggle ON  (older firmware also means enabled)
# AutoBoot    %00   -> toggle OFF (auto boot disabled)
# (no output)        -> treat as OFF / unset
```
`%01` is accepted as **enabled** on read: some Intel firmware reports the older value, and
reading it as OFF would invite the user to "fix" a setting that is already correct.

### Availability

| Platform | Supported | Notes |
|----------|-----------|-------|
| macOS 10.15+ on Intel | ✅ | T2 / T1 security chips and most iMacs/MacBook Pros expose `AutoBoot` |
| macOS 10.15+ on Apple Silicon | ⛔ **Not supported** | M-series Macs boot from an internal volume only; the `AutoBoot` NVRAM variable does not exist, and **NVRAM is reset on every cold boot**, so auto-boot cannot be modified by the user at all. The row is **disabled with a lock icon**, and hovering it shows the tooltip *"Apple Silicon ไม่รองรับ"*. |
| Intel Macs without the variable | ⚠️ Partial | `nvram AutoBoot` returns no output; the toggle shows OFF and writes are ignored by firmware |

### Edge cases
- **This is the primary CPU-gated feature.** `uname -m` returning `arm64` must disable the row
  before the user can interact with it. Disabled, not hidden — see the mock-up. The lock must also
  *explain itself*: SwiftUI's `.help(_:)` is macOS 11+, so the row is wrapped in the AppKit-backed
  `TooltipHost` and shows the owner-specified Thai tooltip **"Apple Silicon ไม่รองรับ"**.
- NVRAM writes persist across reboots, macOS reinstalls, and OS upgrades. There is no per-session
  reset.
- A value outside the expected `%00` / `%01` set must be surfaced as "unknown" rather than
  coerced to a boolean, and the user must be offered an explicit "force enable" / "force disable".
- `nvram` requires root and will fail entirely under a standard user account. Elevation is
  mandatory.
- Writing NVRAM is **not reversible if interrupted** mid-write. Show a confirmation dialog before
  writing, distinct from the standard auth prompt.

---

## 5. Rosetta 2

### Purpose
Install Apple's Rosetta 2 translation environment on Apple Silicon, allowing Intel-only
applications and command-line tools to run natively. One-time install; the app only needs to
detect presence, not manage it.

### Exact command

Install **(admin)** — accepts the licence non-interactively:

```bash
softwareupdate --install-rosetta --agree-to-license
```

### Installed-check (no elevation)
```bash
ls /usr/libexec/oah/libRosettaRuntime
# exists   -> already installed -> button shows "Installed" (disabled)
# missing  -> not installed   -> button shows "Install" (enabled)
```

### Availability

| Platform | Supported | Notes |
|----------|-----------|-------|
| macOS 11+ on Apple Silicon | ✅ | Rosetta 2 ships with Big Sur 11.3+ as an optional component |
| macOS 10.15 (Catalina) | ⛔ | Rosetta 2 does not exist on Catalina — no Apple Silicon hardware runs it |
| macOS 11.0–11.2 on Apple Silicon | ⚠️ | Rosetta 2 not bundled until 11.3; the Install button may fail |
| Intel x64 | ⛔ **Not supported** | Rosetta 2 is a no-op / unavailable; the row is **greyed out** |

### Edge cases
- `softwareupdate` can take **several minutes** and produces long output. The UI must show a
  determinate-ish progress state and a cancel affordance, not a frozen window.
- The download requires a **network connection**. A failure here is an error, not a silent no-op.
- The install is **idempotent**: if Rosetta is already present, the command exits quickly with
  "No new software available". The UI should pre-check with the `libRosettaRuntime` probe and
  avoid prompting for a password at all in that case.
- The button must transition to a disabled **"Installed"** state on success and stay there for
  the rest of the process lifetime.
- A user may be running Rosetta 2 *itself* on an Intel app that launched on Apple Silicon; the
  detection path is unaffected because it is a filesystem probe, not an architecture check.

---

## 6. Spotlight Rebuild

### Purpose
Force macOS Spotlight to discard and rebuild its search index for the startup volume. Fixes
"Spotlight can't find X" after a mass rename, an OS migration, or an external-drive reshuffle.

### Exact command

Rebuild the index for `/` **(admin)**:

```bash
mdutil -E /
```

### State readback
This feature holds no state — it is a one-shot action button. There is nothing to read back and
nothing to disable in the UI beyond the in-flight state.

### Availability

| Platform | Supported | Notes |
|----------|-----------|-------|
| macOS 10.15+ | ✅ | |
| Intel x64 | ✅ | |
| Apple Silicon arm64 | ✅ | |

### Edge cases
- The rebuild is **slow and CPU/I-O intensive**; Spotlight's indexing will visibly churn for
  several minutes afterwards. The UI must warn the user before starting, and the button must show
  a spinner until `mdutil` exits.
- `mdutil -E /` only affects the **startup volume**. If Spotlight indexing is *disabled* for that
  volume (`mdutil -i off`), erasing the index has no effect until indexing is re-enabled. Detect
  this with `mdutil -s /` and warn accordingly.
- On macOS 10.15+, `mdutil -E /` requires root; without elevation it returns
  `Error: unknown index while trying to erase`.
- The command returns success quickly even though the actual rebuild runs in the background.
  Do not report "done" as meaning the index is populated.

---

## 7. DNS Flush

### Purpose
Clear the DNS resolver cache and restart the `mDNSResponder` (multicast DNS) daemon so the Mac
immediately re-resolves hostnames. The standard fix for "the network is up but nothing loads"
after a VPN, DNS-filtering tool, or `/etc/hosts` change.

### Exact command

Flush the cache **(admin)** — both parts are required:

```bash
dscacheutil -flushcache
killall -HUP mDNSResponder
```

### State readback
None — transient action button with no persistent state.

### Availability

| Platform | Supported | Notes |
|----------|-----------|-------|
| macOS 10.15+ | ✅ | |
| Intel x64 | ✅ | |
| Apple Silicon arm64 | ✅ | |

### Edge cases
- **Order matters.** `dscacheutil -flushcache` must run *before* the `SIGHUP`, otherwise the
  responder is reloaded with the stale cache still in place. The implementation must chain them,
  not run them concurrently.
- `killall -HUP mDNSResponder` causes a brief (sub-second) network blip as connections are
  renegotiated. Active downloads and VPN sessions may drop. Warn the user.
- If `mDNSResponder` is not running (rare), `killall` exits non-zero. Treat "cache flushed" as the
  success criterion and suppress the `killall` error.
- Do **not** add a `networksetup -flushdns` invocation on top: it requires enumerating every
  network service and adds failure modes without benefit on modern macOS.

---

## 8. Clear System Cache

### Purpose
Delete the contents of the shared system cache directory at `/Library/Caches/`. The blunt
instrument of last resort for application weirdness, stale permission caches, and corrupted
system-level caches. Caches are regenerated by the OS and applications as they are next needed.

### Exact command

Delete system caches **(admin)**:

```bash
rm -rf /Library/Caches/*
```

### State readback
None — transient action button with no persistent state.

### Availability

| Platform | Supported | Notes |
|----------|-----------|-------|
| macOS 10.15+ | ✅ | |
| Intel x64 | ✅ | |
| Apple Silicon arm64 | ✅ | |

### Edge cases
- ⚠️ **Destructive.** This is the highest-risk action in the app. It requires an explicit
  confirmation dialog *in addition to* the macOS authentication prompt, and the confirmation must
  state that open applications may misbehave and may need to be restarted.
- The feature is **retained deliberately** rather than removed or buried: it is a documented,
  requested capability. What it is *not* allowed to be is quiet about its risk. The warning is one
  constant (`FeatureID.clearSystemCacheWarning`) shared by the panel sheet, the status-item menu
  and the URL-scheme confirmation, so the three can never disagree; it opens with the
  owner-specified Thai line **"⚠️ การล้าง System Cache อาจทำให้บางแอปช้าลงชั่วคราว"** and then
  the English detail. The right-click menu item reads "Clear System Cache…", the ellipsis marking
  the confirmation.
- The glob `*` does not match dotfiles. A literal `rm -rf /Library/Caches/*` will not remove
  hidden entries; this is intentional and must not be "fixed" by switching to a different glob,
  which would risk removing the directory's own metadata.
- Some cache directories are SIP-protected and will simply be skipped; the command still exits 0.
  Do not report a count of deleted files as a success metric.
- Applications with running processes may hold open file handles to deleted files. Their
  behaviour is undefined until restarted — this is expected and must be communicated up front.
- There is **no undo**. The app must never offer a "clear cache" action as part of any automated
  or URL-scheme-driven flow without the same confirmation gate.

---

## 9. URL-scheme actions

Rosetta Stone registers the custom scheme `rosettastone://` via `CFBundleURLTypes`. This is the
only automation surface, and it is what makes all seven Shortcuts actions work **cold** — with the
app not running at all.

### Mode gate: power-user mode only

URL actions belong to **mode B (Run at Startup ON)**. That is the mode in which the app is
always running in the background, so Launch Services always finds a live instance.

In **mode A (Run at Startup OFF, the default)** the app is not running in the background. If a
`rosettastone://` URL arrives anyway — which cold-launches the app through Launch Services — the
action is **refused**: the app logs it, shows the panel with a footer message (*“URL actions
(rosettastone://) work only when Run at Startup is ON — turn it on to switch to menu-bar gadget
mode.”*) and does not perform the action. Malformed/unknown URLs stay silent in every mode.

This is deliberate: the default install must not be remotely actionable by URL. Turning Run at
Startup ON is the explicit opt-in to the automation surface.

### Registered actions

These seven are the complete, exhaustive list. There is no eighth, and the set must match
`README.md` §Shortcuts integration and `docs/USER-GUIDE.md` §9.1 exactly.

| # | Action | Full URL | Maps to | Elevation |
|---|--------|----------|---------|-----------|
| 1 | `open-app` | `rosettastone://open-app` | Show + focus the main window | No |
| 2 | `toggle-gatekeeper` | `rosettastone://toggle-gatekeeper` | Feature 2 | **Yes** (admin) |
| 3 | `toggle-hidden-files` | `rosettastone://toggle-hidden-files` | Feature 3 | No |
| 4 | `flush-dns` | `rosettastone://flush-dns` | Feature 7 | **Yes** (admin) |
| 5 | `rebuild-spotlight` | `rosettastone://rebuild-spotlight` | Feature 6 | **Yes** (admin) |
| 6 | `clear-cache` | `rosettastone://clear-cache` | Feature 8 — still confirms | **Yes** (admin) |
| 7 | `install-rosetta` | `rosettastone://install-rosetta` | Feature 5 | **Yes** (admin) |

There is deliberately **no** URL action for `run-at-startup` or `auto-boot`: both change boot and
login behaviour, and driving them from an untrusted caller with no in-app confirmation would be
unsafe.

### Parsing rules

- The action is the URL's **host** component: `rosettastone://flush-dns` → `flush-dns`.
- Matching is **case-insensitive** (`FLUSH-DNS` works) but **never prefix-matched** —
  `rosettastone://flush-dns-extra` must be rejected as unknown.
- Query and path components are **ignored**, never honoured (`?force=1` is discarded, so an
  injected parameter cannot escalate a harmless call into a dangerous one).
- An unknown or malformed URL is logged and discarded. **No user-facing error.** A shortcut that
  fires at 3 a.m. must never produce an alert nobody asked for.

### Cold-start guarantee (mode B)

All seven actions must work when the app is **not running** and Run at Startup is ON. Launch
Services can deliver `application(_:open:)` before `applicationDidFinishLaunching` has finished
building the status item, so:

1. A URL that arrives early is **queued**, never dropped.
2. The queue is drained immediately after the status item exists, on the main thread.
3. The status item is guaranteed to exist **before** any queued action runs.
4. The queue is a **plain array bounded at 10 entries** (`AppDelegate.maxPendingURLs`), with the
   **oldest** entries dropped on overflow so the most recent intent survives; the drop is logged.
   There is no re-dispatch on the path, so a queued URL cannot be lost and the drain cannot
   re-enter itself.

An action that is unavailable on the current CPU (`install-rosetta` on Intel, for example) is
silently ignored, exactly as it is from the panel.

---

## Cross-cutting behaviour

### Row order (fixed)

| Order | Row | Control |
|-------|-----|---------|
| 1 | Run at Startup | Toggle |
| 2 | Gatekeeper | Toggle |
| 3 | Hidden Files | Toggle |
| 4 | Auto Boot | Toggle (greyed + 🔒 on Apple Silicon) |
| 5 | Rosetta 2 | Install button (greyed on Intel) |
| 6 | Quick Tools — Spotlight | Button |
| 6 | Quick Tools — DNS | Button |
| 6 | Quick Tools — Cache | Button |

### Toggle semantics
| Feature | ON means |
|---------|---------|
| Run at Startup | The LaunchAgent plist exists — the app is a menu-bar gadget (mode B) |
| Gatekeeper | **Gatekeeper is disabled** (inverted — ON = insecure state) |
| Hidden Files | **Hidden files are shown** (inverted vs. the system default) |
| Auto Boot | Auto boot is enabled |

Two of the four toggles are inverted. The UI must label them unambiguously (for example
"Gatekeeper — Off" vs "Gatekeeper — Bypassed") so a user never misreads the switch position.

### Concurrency
- Only one privileged operation may be in flight at a time. A second request while one is
  running must be queued or rejected with an explanatory message — never two simultaneous
  `osascript` auth dialogs.
- Quick Tools buttons must disable themselves for the duration of their own execution.

### Feedback
Every action produces exactly one terminal state: **success**, **cancelled by the user at the
auth prompt**, or **failed with a message**. No action may fail silently.



