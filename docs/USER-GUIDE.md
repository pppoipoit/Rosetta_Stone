# Rosetta Stone — User Guide

Version 0.1.0 · macOS 10.15 Catalina and newer · Intel and Apple Silicon

---

## 1. What Rosetta Stone is

A small utility that puts the macOS settings power users fiddle with constantly into one panel:
startup behaviour, Gatekeeper, hidden files, Auto Boot, Rosetta 2, and a few one-shot maintenance
commands.

Rosetta Stone has **two modes**, chosen by the **Run at Startup** toggle:

- **OFF (the default):** a normal windowed app — panel at launch, Dock icon, no menu-bar icon.
- **ON (power-user mode):** a menu-bar gadget — it launches hidden, has no Dock icon,
  **left-click** toggles Gatekeeper, **right-click** opens the full menu, and the Shortcuts URL
  actions work.

You can switch between them whenever you like; the change takes effect immediately, with no
relaunch.

Every feature is a thin wrapper around a command you could type in Terminal yourself. Nothing is
uploaded, nothing is tracked, and there is no account.

---

## 2. System requirements

| Item | Requirement |
|------|-------------|
| macOS | 10.15 Catalina or newer (tested through macOS 27 Golden Gate) |
| Chip | Intel or Apple Silicon — download the matching DMG |
| Account | An administrator account (7 of 8 features ask for your password) |
| Network | Only needed for the Rosetta 2 install |

Check which chip you have:  → **Apple menu → About This Mac**.

---

## 3. Installation

1. Go to the **Releases** page on the project repository.
2. Download the file that matches your Mac:
   - `RosettaStone-AppleSilicon.dmg` — M1, M2, M3, M4 Macs.
   - `RosettaStone-Intel.dmg` — older Intel Macs.
3. Open the downloaded DMG.
4. Drag the **Rosetta Stone** icon onto the **Applications** icon.
5. Close the DMG window, then **eject** the disk from the sidebar.
6. Open **Applications → Rosetta Stone**.

> **The app is called the same thing on every Mac.** Only the **`.dmg` file name** differs between
> Intel and Apple Silicon. The bundle inside is always **`RosettaStone.app`**, so it always installs
> to **`/Applications/RosettaStone.app`** — never `RosettaStone-Intel.app` or
> `RosettaStone-AppleSilicon.app`. If you still have one of those older names in **Applications**,
> delete it: it is a previous build, and two copies can conflict.

Rosetta Stone opens as a **normal windowed app** with a Dock icon; there is no menu-bar icon in
this default mode. The **Diagnostics…** link in the panel footer is always available. To switch
to the menu-bar mode, turn **Run at Startup** ON (§6.1).

---

## 4. First run with Gatekeeper ON

### 4.1 What to expect

Rosetta Stone is signed **ad-hoc**. It has **no Developer ID** and it has **never been notarised**
by Apple. That is a deliberate choice, and it has one honest consequence:

> **Ad-hoc signing cannot silently bypass Gatekeeper.** macOS will ask you to approve the app
> the first time you open it. This is expected, it is not a broken download, and it happens
> **once**.

You need to do **one** of the two things below. Both are permanent for this copy of the app.

### 4.2 Option A — right-click → Open (one click, no Terminal)

1. Open **Applications** in the Finder.
2. **Right-click** (or Control-click) **Rosetta Stone**.
3. Choose **Open** in the menu that appears.
4. A dialog confirms — click **Open** again.
5. The app opens. This approval is remembered; you will not be asked again.

If **Open** is not offered and the app refuses to start, macOS is still holding the download
quarantine flag. Use Option B.

### 4.3 Option B — run the first-run script (removes the quarantine flag)

The repository ships `scripts/first-run.sh`. It removes only the quarantine attribute that
macOS applies to downloaded files — it does **not** disable Gatekeeper and does not weaken
your Mac in any way.

```bash
# from a Terminal, in the folder where you unpacked the repository
bash scripts/first-run.sh
```

Or with the app in a non-standard location:

```bash
bash scripts/first-run.sh "/path/to/RosettaStone.app"
```

What the script does, and what it does not:

| Does | Does not |
|------|----------|
| Removes `com.apple.quarantine` recursively from the app bundle | Disable Gatekeeper |
| Work on `/Applications/RosettaStone.app`, the one canonical name | Bypass any other macOS security check |
| Warn you if an older `RosettaStone-Intel.app` / `RosettaStone-AppleSilicon.app` is still installed | **Delete those old copies for you** |
| Tell you clearly if the app was not found | Modify the app itself |

The script prints a reminder about older `RosettaStone-Intel.app` / `RosettaStone-AppleSilicon.app`
bundles, but removing an app is your decision — drag them to the Trash yourself if they are there.

The equivalent one-liner, if you would rather not run the script:

```bash
xattr -dr com.apple.quarantine "/Applications/RosettaStone.app"
```

### 4.4 Verifying the first run worked

In the default mode Rosetta Stone **opens its panel** at launch: the app starts as an ordinary
windowed app, so a brand-new installation can never look like it silently failed.

You should see a dark panel with the feature rows and a Dock icon.

If you do not, open **Diagnostics…** — from the link in the panel footer, or by Control-clicking
the menu-bar glyph in power-user mode — click **Copy Report**, and paste it into a bug report.

### 4.5 Two different "Gatekeeper" things

Worth separating, because they look identical on screen:

| | What it is | What you do |
|---|------------|-------------|
| **First run** (§4.1–4.4) | macOS checking *this app* the first time you open it | Control-click → **Open** once (§4.2), or run `scripts/first-run.sh` (§4.3) |
| **The Gatekeeper toggle** (§6.2) | Rosetta Stone turning macOS's Gatekeeper off for *everything on the Mac* | Your password — and on **macOS 15 Sequoia and later** it is a **two-step** procedure: after the command succeeds the app opens **System Settings → Privacy & Security** and shows a confirmation dialog — *"กรุณาเลือก 'Anywhere' ใน System Settings เพื่อยืนยันการปิด Gatekeeper"* — after which you choose **Anywhere** to finish |

---

## 5. The panel

The window is dark-themed and laid out top to bottom as follows.

| Row | Control | What it does |
|-----|---------|--------------|
| **Run at Startup** | Toggle | Switch modes: install / remove the login item and the menu-bar icon |
| **Gatekeeper** | Toggle | Disable / re-enable macOS Gatekeeper |
| **Hidden Files** | Toggle | Show / hide dotfiles in Finder |
| **Auto Boot** | Toggle | Power on automatically — **Intel only** |
| **Rosetta 2** | Install button | Install the Rosetta 2 translator — **Apple Silicon only** |
| **Quick Tools** | 3 buttons | Spotlight / DNS / Cache |

### The menu-bar icon (power-user mode only)

The glyph exists only while **Run at Startup** is ON (§6.1).

| Gesture | What it does |
|---------|--------------|
| **Left-click** | Toggles Gatekeeper immediately — no menu, no window. You get the password prompt, then a small toast under the icon with the result |
| **Right-click** (or Control-click) | Opens the full menu: Open Main Window, Toggle Hidden Files, Flush DNS, Rebuild Spotlight, Clear System Cache… (asks first), **Diagnostics…** (⌘D), Quit (⌘Q) |

Hover the glyph and the tooltip tells you Gatekeeper's current state and what a left-click will
do.

> **The icon does not appear at all?** On **macOS 26 Tahoe and later** you can hide it in System
> Settings: **System Settings → Menu Bar → Rosetta Stone → allow the item in the Menu Bar**. Turn
> it back on there. (ถ้าไอคอนไม่โผล่ ให้ไปที่ System Settings → Menu Bar → หา Rosetta Stone →
> เปิดสวิตช์ Allow in the Menu Bar.) **Diagnostics…** reports whether AppKit thinks the item is
> visible at all.

### Diagnostics

**Diagnostics…** — the link in the panel footer, or ⌘D in the menu-bar menu — shows the state of
the running app: CPU architecture, **Mac model name and form factor**, macOS version, process ID,
launch mode, activation policy, the status item's measured width and which icon it resolved, and
whether the login item is installed.

It also reports the Auto Boot decision directly — *Auto Boot supported* (Yes/No) and *Auto Boot
lock reason* (the exact sentence the row is showing you) — so a greyed-out Auto Boot row can be
diagnosed from a pasted report without guessing.

Use it whenever something looks wrong — an empty menu-bar slot, a missing icon, or a login item
that does not fire. Click **Copy Report** and paste the result into a bug report; it replaces a
round of "did it even start?" questions.

### The lock icon

A greyed-out row with a **padlock** at the right means the feature does not apply to your Mac. The row
is kept visible — rather than hidden — so the app looks identical on every machine.

| Row | Locked on |
|-----|-----------|
| Auto Boot | Apple Silicon **and** desktops (iMac, Mac mini, Mac Studio, Mac Pro) |
| Rosetta 2 | Intel |

Hovering a locked row shows a tooltip saying why — the same sentence shown under the row title, so a
greyed row always explains itself.

> **ทำไมปุ่ม Auto Boot ถึงจาง?** — มี 3 เหตุผล และแอปจะบอกเหตุผลที่ตรงกับเครื่องคุณบนแถวเอง:
>
> 1. **Apple Silicon** — firmware ของชิป M-series เป็นเจ้าของค่า `AutoBoot` และ **NVRAM ถูกล้างทุกครั้งที่
>    cold boot** ค่านี้จึงเปลี่ยนโดยผู้ใช้ไม่ได้เลย
>    → *"Apple Silicon reset NVRAM ทุกครั้งที่ cold boot"*
> 2. **เครื่องตั้งโต๊ะ (Desktop)** — ไม่มีฝาให้เปิด พฤติกรรมที่สวิตช์นี้ควบคุมจึงไม่มีอยู่จริง
>    → *"Desktop Mac ไม่มีฝาเปิด-ปิด"*
> 3. **อ่านชื่อเครื่องไม่ได้** — `system_profiler` ช้า ถูกนโยบายบล็อก หรือไม่มีในระบบ
>    → *"Unknown Mac model — Auto Boot is disabled to stay safe."*
>
> ปุ่ม Auto Boot จะใช้งานได้**เฉพาะ MacBook ที่ใช้ชิป Intel เท่านั้น** ทั้งสามกรณีข้างบนเป็นการ
> "ปิดทางเข้า" โดยเจตนา เพราะการเขียนค่า NVRAM ผิดที่เป็นการเปลี่ยนแปลงถาวรที่ย้อนกลับไม่ได้
> จึงเลือกให้ปุ่มที่เห็นเป็นสีเทาพร้อมบอกเหตุผล ดีกว่าปล่อยให้กดแล้วเขียนค่าลงเครื่อง

เปิด **Diagnostics…** (§5) เพื่อดู *Model name*, *Form factor*, *Auto Boot supported* และ
*Auto Boot lock reason* ของเครื่องคุณได้โดยตรง แล้วคัดลอกไปแนบในบั๊กราฟได้เลย

---

## 6. Using each feature

### 6.1 Run at Startup — the mode switch

This toggle does two things at once: it installs a login item at
`~/Library/LaunchAgents/com.rosettastone.helper.plist`, **and** it switches the app's mode.

| | OFF (default) | ON (power-user mode) |
|---|---------------|----------------------|
| At launch | panel opens | starts hidden |
| Dock icon | yes | no |
| Menu-bar icon | none | always |
| Left-click the icon | — | toggles Gatekeeper directly |
| Right-click the icon | — | full menu |
| `rosettastone://` actions | refused (the app is not running in the background) | all seven work |

Both directions take effect **immediately** — no relaunch:

- Turning it **ON** installs the login item, the Dock icon disappears and the stone glyph appears
  in the menu bar. The panel you are looking at stays open; from the next login the app starts
  hidden.
- Turning it **OFF** removes the login item, removes the glyph, and restores the Dock icon and
  normal window behaviour.

- Requires your administrator password.
- If you move Rosetta Stone to a different folder after turning this on, turn it off and on again
  so the login item is regenerated with the new path.
- Login items created by an older version did not pass the menu-bar-only flag. Turn the toggle off
  and on once to regenerate it; **Diagnostics…** reports whether yours is current.
- With the toggle ON, double-clicking the app in Finder also opens it in gadget mode (hidden).
  Use the right-click menu → **Open Main Window** to see the panel.

### 6.2 Gatekeeper

**ON means Gatekeeper is bypassed** — the less secure state. This is intentional: the switch shows
what you have actually disabled rather than a vague "on".

| Switch | Meaning |
|--------|---------|
| OFF | Gatekeeper is active and evaluating every app you open (recommended) |
| ON | Gatekeeper's master switch is disabled — unsigned software runs without warnings |

- Requires your administrator password.
- **On macOS 15 Sequoia and later, turning it ON is a two-step procedure.** After the password
  prompt, Rosetta Stone opens **System Settings → Privacy & Security** and shows a confirmation
  dialog: *"กรุณาเลือก 'Anywhere' ใน System Settings เพื่อยืนยันการปิด Gatekeeper"*. Choose
  **Anywhere** under *Allow applications from* to complete the change. Turning it OFF is always a
  single step.
- If your Mac is managed by your employer or school, this setting may be enforced by policy and
  will switch itself back on. Rosetta Stone re-reads the real state after every change, so the
  switch will snap back to reflect reality.
- **Turn it back on when you are done.** This is the most security-sensitive control in the app.

### 6.3 Hidden Files

**ON means hidden files are visible** in Finder.

- Toggling it restarts Finder, so your desktop and Dock briefly disappear and reappear. This is
  normal and takes about a second.
- **No password required** — this is the only feature in the app that does not ask.

### 6.4 Auto Boot — Intel MacBook only

Controls whether your Mac powers on by itself when power is restored or the power button is
pressed.

- Requires your administrator password.
- It writes to NVRAM, which is permanent firmware storage. If you turn it off by mistake, use
  Rosetta Stone to turn it back on — but if the write is interrupted the Mac may not auto-power
  until you do.
- **Only Intel MacBooks can use it.** Anywhere else the row is locked and states which of the three
  reasons applies — see the *lock icon* box in §5 for all three, in Thai.
- On a supported machine the command is `nvram AutoBoot=%03` to enable and `%00` to disable.

| Your Mac | Row | Why |
|----------|-----|-----|
| Intel MacBook / Air / Pro | Enabled | The only supported combination. |
| Apple Silicon MacBook | Locked 🔒 | Firmware owns the setting; NVRAM is reset every cold boot. |
| iMac, Mac mini, Mac Studio, Mac Pro | Locked 🔒 | No lid — and on Intel desktops the variable is absent or ignored. |
| Unrecognised model | Locked 🔒 | The app cannot identify the machine and fails safe. |

### 6.5 Rosetta 2 — Apple Silicon only

Installs Rosetta 2 so Intel-only applications and command-line tools will run.

- Greyed out on Intel, where Rosetta 2 is meaningless.
- Requires your administrator password **and** an internet connection.
- Takes a few minutes. The button shows progress — do not quit the app while it works.
- If Rosetta 2 is already installed, the button reads **Installed** and is disabled, and no
  password prompt appears.
- There is no uninstall button. To remove it, use the official Apple removal command in Terminal.

### 6.6 Quick Tools

Three one-shot buttons. None of them holds an ON/OFF state — they do a thing and reset.

| Button | What happens | Cost |
|--------|--------------|------|
| **Spotlight** | Erases and rebuilds the Spotlight search index. Expect several minutes of heavy CPU and disk activity afterwards. | Password |
| **DNS** | Clears the DNS cache and restarts the network resolver. Your network blips for a fraction of a second; active downloads and VPN sessions may drop. | Password |
| **Cache** | Deletes the contents of `/Library/Caches`. **There is no undo.** | Password + confirmation |

> ⚠️ **Before pressing Cache:** *"⚠️ การล้าง System Cache อาจทำให้บางแอปช้าลงชั่วคราว"* — open
> applications may start misbehaving and may need to be restarted. Caches regenerate on their own,
> but the gap in between can be noticeable. Close what you can, and consider restarting afterwards.
> The same warning appears in the right-click menu's **Clear System Cache…** confirmation.

A button stays disabled while its own action is running, and only one privileged action runs at a
time, so you will never get two password dialogs stacked on top of each other.

---

## 7. Things worth knowing

| Situation | What it means |
|-----------|--------------|
| You cancelled the password prompt | The switch snaps back to where it was. Nothing was changed. No error is shown — cancelling is a normal outcome, not a failure. |
| The password was wrong three times | macOS locks out further attempts temporarily. Wait a few minutes and try again. |
| A toggle did not stick | Something else changed the setting — usually a corporate management profile. Rosetta Stone re-reads the real state and shows it to you. |
| Finder restarted | Expected after toggling Hidden Files. |
| Nothing is in the Dock | Expected in power-user mode (Run at Startup ON). Turn it OFF to get the Dock icon back. |
| There is no menu-bar icon | Expected in the default mode. Turn **Run at Startup** ON (§6.1) to switch to menu-bar mode. |
| The app does not reappear after reboot | It only does so in power-user mode: turn **Run at Startup** on, then log out and back in. |

---

## 8. Uninstalling

1. Quit the app: **right-click the glyph → Quit** in power-user mode, or **⌘Q** in the default
   mode.
2. Drag **Rosetta Stone** from **Applications** to the **Trash**.
3. Empty the Trash.

Optional cleanup — remove the login item if you had enabled it:

```bash
rm -f ~/Library/LaunchAgents/com.rosettastone.helper.plist
```

(No `launchctl` call is needed: deleting the file is what stops the app from starting at the next
login. A loaded job from the current session cannot restart the app and disappears at logout.)

Rosetta Stone keeps no other files, no preferences, and no caches. Uninstalling removes everything
it added.

> **Note:** if you used the **Gatekeeper** toggle or **Auto Boot** while the app was installed, those
> are system settings, not app settings. Uninstalling Rosetta Stone does not re-enable Gatekeeper or
> restore Auto Boot. Use Rosetta Stone one last time to set them back before you quit.

---

## 9. Apple Shortcuts

Rosetta Stone can be driven from Apple Shortcuts through its `rosettastone://` URL scheme. This lets
you put a system action on a keyboard shortcut, a Siri voice command, or an automation.

> **Power-user mode required.** URL actions only work while **Run at Startup** is ON (§6.1). In the
> default mode the app is not running in the background, so a URL is refused and the panel opens
> with an explanation.

### 9.1 The action list

| Action | URL | Password? | Works on |
|--------|-----|----------|----------|
| Open the app | `rosettastone://open-app` | No | All |
| Toggle Gatekeeper | `rosettastone://toggle-gatekeeper` | Yes | All |
| Toggle Hidden Files | `rosettastone://toggle-hidden-files` | No | All |
| Flush DNS | `rosettastone://flush-dns` | Yes | All |
| Rebuild Spotlight | `rosettastone://rebuild-spotlight` | Yes | All |
| Clear system cache | `rosettastone://clear-cache` | Yes (plus a confirmation) | All |
| Install Rosetta 2 | `rosettastone://install-rosetta` | Yes | Apple Silicon only |

An action that does not apply to your Mac — `install-rosetta` on an Intel Mac, for example — is
silently ignored. No error, no alert. So is an unknown URL. A **recognised** action sent while
**Run at Startup** is OFF is *deliberately refused*: the panel opens and the footer explains that
the power-user mode is required.

### 9.2 Build a shortcut

1. Open **Shortcuts** (built into macOS, in Applications → Utilities).
2. Click **+** to create a new shortcut.
3. On the right, search for and add the action **Open URLs**.
4. Replace the example URL with one from the table above, for example
   `rosettastone://flush-dns`.
5. Give the shortcut a name, e.g. **Flush DNS**.
6. Click the ⌘ icon at the top of the shortcut window to assign a keyboard shortcut.

To try it immediately, click the ▶ button at the top of the Shortcuts window.

### 9.3 Example shortcuts

| Shortcut name | URL | Suggested use |
|---------------|-----|---------------|
| Show/Hide Hidden Files | `rosettastone://toggle-hidden-files` | Bind to ⌘⇧. — the classic dotfile key |
| Flush DNS | `rosettastone://flush-dns` | Run from a terminal-adjacent workflow after switching VPN |
| Open Main Window | `rosettastone://open-app` | Power-user mode: show the panel without touching the glyph |
| Rebuild Spotlight | `rosettastone://rebuild-spotlight` | Run overnight, e.g. at 2 a.m. |
| Install Rosetta 2 | `rosettastone://install-rosetta` | One-time setup, Apple Silicon only |

### 9.4 Test from Terminal first

Before building a shortcut, confirm the URL works:

```bash
open "rosettastone://open-app"
```

`open-app` is the safest test: it has no side effects. If the app window appears, the URL scheme is
registered correctly and the rest will work too.

### 9.5 Use it from a shell script

```bash
#!/bin/bash
# Rebuild Spotlight only when the battery is above 50%
if [ "$(pmset -g batt | awk '/Battery/ {print int($2*100)}')" -gt 50 ]; then
  open "rosettastone://rebuild-spotlight"
fi
```

### 9.6 Use it with Alfred or Raycast

Both can run a plain shell command. Set the command to:

```bash
open "rosettastone://flush-dns"
```

### 9.7 Automation notes

| Consideration | Detail |
|---------------|--------|
| Password prompts | Any action marked *Yes* above still raises the macOS password dialog, even when triggered by an automation. macOS has no way to pre-authorise a GUI script, so your automation will pause until you type your password. |
| Background execution | In power-user mode, an action triggered while the app is closed cold-launches it into the background — **no window appears**. That is intentional. The action is queued and runs as soon as the app finishes starting, so a cold start works exactly like a warm one. In the default mode the URL is refused instead. |
| Silent success | Nothing pops up to tell you it worked. Check the toggle state, or add a `Notify` action in Shortcuts if you want feedback. |
| Destructive actions | `clear-cache` keeps its confirmation dialog even when driven by a URL. Automating it requires you to click **Confirm** each time. |
| Duplicating actions | Toggling actions flip state. Do not put `toggle-gatekeeper` in a shortcut that runs repeatedly — use it deliberately. |

---

## 10. Safety notes

> ⚠️ Rosetta Stone runs commands that change your system. Before you use it:

- **Keep backups current.** Time Machine, at minimum. The cache-clearing and Auto Boot features
  have no undo.
- **Understand what each switch does.** The panel labels the security-relevant ones, but a toggle
  named "Gatekeeper" that turns a *security feature off* deserves a second thought.
- **Re-enable Gatekeeper when you are finished** with whatever unsigned tool required disabling it.
- **Do not script around the confirmation dialogs.** They exist because the actions are destructive.
- **Rosetta Stone is not signed by a known developer.** Verify your download source before
  overriding Gatekeeper.

Rosetta Stone is provided "as is", without warranty of any kind. You are responsible for your
machine.

---

## 11. Troubleshooting

| Problem | Try this |
|---------|----------|
| "Cannot be opened because the developer cannot be verified" | Control-click → **Open** (§4.2), or run `scripts/first-run.sh` (§4.3) |
| No menu-bar icon (Run at Startup ON) | Open **Diagnostics…** (§5). If the status item reports a width of 0 the icon failed to render; if it reports "MISSING" the app did not finish creating it. |
| No menu-bar icon (Run at Startup OFF) | Expected — the default mode has no menu-bar icon. Turn **Run at Startup** ON (§6.1) to switch modes. |
| No menu-bar icon even in power-user mode | Check **System Settings → Menu Bar → Rosetta Stone → Allow in the Menu Bar** — macOS 26 Tahoe and later let you hide a third-party status item. (ถ้าไอคอนไม่โผล่ ไปที่ System Settings → Menu Bar → หา Rosetta Stone → เปิดสวิตช์ Allow in the Menu Bar.) **Diagnostics…** also reports whether AppKit considers the item visible at all. |
| Nothing at all appears at launch | The default mode opens the panel at launch (§4.4). If it did not, check **Diagnostics…**. |
| App does not start at login | Toggle **Run at Startup** off, then on again, then log out and back in. **Diagnostics…** shows whether the login item is installed and whether it is stale. |
| A Shortcut did nothing | URL actions require **Run at Startup ON** (§9). With the toggle off, the panel opens and says so. In power-user mode, actions perform silently once running — see §9.7. |
| Gatekeeper did not switch off on macOS 15+ | On Sequoia/Tahoe you must also choose **Anywhere** in System Settings; the app opens the pane and reminds you (§6.2). |
| Password prompt never appears | Check that a previous `osascript` dialog is not hidden behind another window. Only one privileged action runs at a time. |
| "Operation not permitted" | You cancelled the prompt, or the command needs root and did not get it. Retry and complete the password prompt. |
| Rosetta 2 install fails | You need an internet connection. On macOS 11.0–11.2 the component is not bundled; update to 11.3+ first. |
| Auto Boot toggle is greyed | Auto Boot works on **Intel MacBooks only**. Three reasons: (1) Apple Silicon — firmware owns the setting and NVRAM is reset every cold boot; (2) a desktop — there is no lid; (3) the model could not be read, and the app fails safe. The row itself names your reason, and hovering repeats it (§6.4). **Diagnostics…** reports *Auto Boot supported* and *Auto Boot lock reason*. |
| Gatekeeper toggle keeps flipping back | Your Mac is managed by an organisation profile. That profile wins. |
| Finder vanished | It restarted after toggling Hidden Files. It comes back on its own within a second. |

---

## 12. Further reading

| Document | For |
|----------|-----|
| [FEATURES.md](FEATURES.md) | Exact commands behind every toggle, and the edge cases |
| [ARCHITECTURE.md](ARCHITECTURE.md) | How the app works internally |
| [CI-CD.md](CI-CD.md) | How releases are built |
| [DECISIONS.md](DECISIONS.md) | Why the app is built the way it is |
| [CHANGELOG.md](../CHANGELOG.md) | What changed in each release |



