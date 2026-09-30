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
login. Because the app is an `LSUIElement` agent, "launched" means *menu-bar icon appears* — no
Dock icon, no window stealing focus.

### Exact command

Installation — writes a property list to the user's LaunchAgents directory **(admin)**:

```bash
# Managed internally as: write plist -> launchctl load
cat > ~/Library/LaunchAgents/com.rosettastone.helper.plist
launchctl load ~/Library/LaunchAgents/com.rosettastone.helper.plist
```

The generated `com.rosettastone.helper.plist` targets the app's own bundle identifier
(`com.rosettastone.app`) with `RunAtLoad = true`.

Removal **(admin)**:

```bash
launchctl unload ~/Library/LaunchAgents/com.rosettastone.helper.plist
rm -f ~/Library/LaunchAgents/com.rosettastone.helper.plist
```

### State readback
Toggle state = *does `~/Library/LaunchAgents/com.rosettastone.helper.plist` exist?*
No elevation is needed to **read** this; elevation is only required to create/remove.

### Availability

| Platform | Supported | Notes |
|----------|-----------|-------|
| macOS 10.15+ | ✅ | `launchctl load` semantics |
| Intel x64 | ✅ | |
| Apple Silicon arm64 | ✅ | Runs natively; no Rosetta required |

### Edge cases
- The plist path is per-user. Elevation is still used so the file is written outside a
  sandboxed / read-only context; if the process runs unelevated, the write falls back to the
  invoking user's home only.
- A **stale** plist may exist from a previous install at a different path. The app must treat
  "file exists" as ON even if `launchctl list` shows no loaded job, and offer a clean reinstall.
- If the user drags the app to a different location after enabling, the plist's
  `ProgramArguments` path becomes stale. The UI must show a warning until the user re-toggles
  the switch (off → on) to regenerate it.
- `launchctl unload` fails if the job was never loaded; the implementation must not surface this
  as a user-visible error when the plist deletion succeeded.

---

## 2. Gatekeeper

### Purpose
Toggle macOS Gatekeeper's *master switch* between enforcing and disabled. Useful when a
developer needs to run an unsigned or unnotarized tool (a Homebrew cask, an internal build, a
legacy installer) without Gatekeeper blocking it.

> ⚠️ This is a security-critical toggle. Turning it off removes one of the OS's main protections
> against running untrusted software.

### Exact command

Disable **(admin)**:

```bash
spctl --master-disable
```

Enable **(admin)**:

```bash
spctl --master-enable
```

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
| macOS 10.15–12 | ✅ | |
| macOS 13+ (Ventura) and later | ✅ | Apple removed the `--master-disable` option in macOS 13 for some policy-managed configurations; the command may return a non-zero exit code. Treat that as a failure and show the stderr. |
| Intel x64 | ✅ | |
| Apple Silicon arm64 | ✅ | |

### Edge cases
- On **Apple Silicon**, Gatekeeper is stricter and some enterprise MDM configurations
  re-enable it immediately. The app must re-read `spctl --status` after the command completes
  and reflect reality rather than optimistically assuming success.
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
- `%01` = binary `001` = **enabled** (toggle ON)

> Note the deliberate divergence from the other features: here **ON = auto boot enabled**,
> matching the system default. Only Hidden Files uses inverted semantics.

### Exact command

Enable auto boot **(admin)**:

```bash
nvram AutoBoot=%01
```

Disable auto boot **(admin)**:

```bash
nvram AutoBoot=%00
```

### State readback
```bash
nvram AutoBoot
# AutoBoot    %01   -> toggle ON  (auto boot enabled)
# AutoBoot    %00   -> toggle OFF (auto boot disabled)
# (no output)        -> treat as OFF / unset
```

### Availability

| Platform | Supported | Notes |
|----------|-----------|-------|
| macOS 10.15+ on Intel | ✅ | T2 / T1 security chips and most iMacs/MacBook Pros expose `AutoBoot` |
| macOS 10.15+ on Apple Silicon | ⛔ **Not supported** | Apple Silicon Macs boot from an internal volume only; the `AutoBoot` NVRAM variable does not exist. The row is **greyed out with a lock icon**. |
| Intel Macs without the variable | ⚠️ Partial | `nvram AutoBoot` returns no output; the toggle shows OFF and writes are ignored by firmware |

### Edge cases
- **This is the primary CPU-gated feature.** `uname -m` returning `arm64` must disable the row
  before the user can interact with it. Disabled, not hidden — see the mock-up.
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
| Run at Startup | The LaunchAgent plist exists |
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



