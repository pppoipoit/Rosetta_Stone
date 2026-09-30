# Rosetta Stone — User Guide

Version 0.1.0 · macOS 10.15 Catalina and newer · Intel and Apple Silicon

---

## 1. What Rosetta Stone is

A small utility that puts the macOS settings power users fiddle with constantly into one panel:
startup behaviour, Gatekeeper, hidden files, Auto Boot, Rosetta 2, and a few one-shot maintenance
commands.

It lives in your **menu bar** (the row of icons at the top-right of your screen), not the Dock. It
has no Dock icon, so it never takes up space among your other apps.

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

Rosetta Stone appears as a small stone glyph in your menu bar. It has **no Dock icon** — this is
intentional. To open the panel, click the menu-bar glyph.

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
| Work on either `RosettaStone.app` or `Rosetta Stone.app` | Bypass any other macOS security check |
| Tell you clearly if the app was not found | Modify the app itself |

The equivalent one-liner, if you would rather not run the script:

```bash
xattr -dr com.apple.quarantine "/Applications/RosettaStone.app"
```

### 4.4 Verifying the first run worked

On first launch Rosetta Stone **opens its panel once**. This is intentional: the app has no
Dock icon, so without it a brand-new installation would look like it had failed to start.

You should see a dark panel with the six feature rows, and a stone glyph in your menu bar.

If you see neither, open **Diagnostics** to find out why:

1. Control-click the menu-bar glyph.
2. Choose **Diagnostics…**.
3. Click **Copy Report** and paste it into a bug report.

---

## 5. The panel

The window is dark-themed and laid out top to bottom as follows.

| Row | Control | What it does |
|-----|---------|--------------|
| **Run at Startup** | Toggle | Install / remove the login item |
| **Gatekeeper** | Toggle | Disable / re-enable macOS Gatekeeper |
| **Hidden Files** | Toggle | Show / hide dotfiles in Finder |
| **Auto Boot** | Toggle | Power on automatically — **Intel only** |
| **Rosetta 2** | Install button | Install the Rosetta 2 translator — **Apple Silicon only** |
| **Quick Tools** | 3 buttons | Spotlight / DNS / Cache |

### The menu-bar menu

Click the menu-bar glyph to open the panel. Control-clicking the same glyph gives a small menu with
quick access to the app, its version, **Diagnostics…**, and a Quit command. The app has no Dock
icon, so this menu and the panel are the only ways to reach it once running.

### Diagnostics

**Diagnostics…** (or press ⌘D with the menu open) shows the state of the running app: CPU
architecture, macOS version, process ID, activation policy, launch posture, the status item's
measured width and which icon it resolved, and whether the login item is installed.

Use it whenever something looks wrong — an empty menu-bar slot, a missing icon, or a login item
that does not fire. Click **Copy Report** and paste the result into a bug report; it replaces a
round of "did it even start?" questions.

### The lock icon

A greyed-out row with a **padlock** at the right means the feature does not apply to your Mac's
chip. The row is kept visible — rather than hidden — so the app looks identical on every machine.

| Row | Locked on |
|-----|-----------|
| Auto Boot | Apple Silicon |
| Rosetta 2 | Intel |

---

## 6. Using each feature

### 6.1 Run at Startup

**ON** installs a login item at `~/Library/LaunchAgents/com.rosettastone.helper.plist` so the
menu-bar icon appears automatically every time you log in. **OFF** removes it.

The login item starts the app as a **menu-bar gadget only** — no window opens at login, and there
is no Dock icon. Click the glyph to open the panel whenever you want it.

- Requires your administrator password.
- If you move Rosetta Stone to a different folder after turning this on, turn it off and on again
  so the login item is regenerated with the new path.
- Login items created by an older version did not pass the menu-bar-only flag. Turn the toggle off
  and on once to regenerate it; **Diagnostics…** reports whether yours is current.

### 6.2 Gatekeeper

**ON means Gatekeeper is bypassed** — the less secure state. This is intentional: the switch shows
what you have actually disabled rather than a vague "on".

| Switch | Meaning |
|--------|---------|
| OFF | Gatekeeper is active and evaluating every app you open (recommended) |
| ON | Gatekeeper's master switch is disabled — unsigned software runs without warnings |

- Requires your administrator password.
- If your Mac is managed by your employer or school, this setting may be enforced by policy and
  will switch itself back on. Rosetta Stone re-reads the real state after every change, so the
  switch will snap back to reflect reality.
- **Turn it back on when you are done.** This is the most security-sensitive control in the app.

### 6.3 Hidden Files

**ON means hidden files are visible** in Finder.

- Toggling it restarts Finder, so your desktop and Dock briefly disappear and reappear. This is
  normal and takes about a second.
- **No password required** — this is the only feature in the app that does not ask.

### 6.4 Auto Boot — Intel only

Controls whether your Mac powers on by itself when power is restored or the power button is
pressed.

- Requires your administrator password.
- It writes to NVRAM, which is permanent firmware storage. If you turn it off by mistake, use
  Rosetta Stone to turn it back on — but if the write is interrupted the Mac may not auto-power
  until you do.
- Greyed out with a lock icon on Apple Silicon, where this setting does not exist.

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

> ⚠️ **Before pressing Cache:** open applications may start misbehaving and may need to be
> restarted. Caches regenerate on their own, but the gap in between can be noticeable. Close what
> you can, and consider restarting afterwards.

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
| Nothing is in the Dock | Expected. The app is a menu-bar agent by design. |
| The app does not reappear after reboot | Turn **Run at Startup** on, then log out and back in. |

---

## 8. Uninstalling

1. Click the menu-bar glyph, then Control-click for the menu, and choose **Quit**.
2. Drag **Rosetta Stone** from **Applications** to the **Trash**.
3. Empty the Trash.

Optional cleanup — remove the login item if you had enabled it:

```bash
launchctl unload ~/Library/LaunchAgents/com.rosettastone.helper.plist 2>/dev/null
rm -f ~/Library/LaunchAgents/com.rosettastone.helper.plist
```

Rosetta Stone keeps no other files, no preferences, and no caches. Uninstalling removes everything
it added.

> **Note:** if you used the **Gatekeeper** toggle or **Auto Boot** while the app was installed, those
> are system settings, not app settings. Uninstalling Rosetta Stone does not re-enable Gatekeeper or
> restore Auto Boot. Use Rosetta Stone one last time to set them back before you quit.

---

## 9. Apple Shortcuts

Rosetta Stone can be driven from Apple Shortcuts through its `rosettastone://` URL scheme. This lets
you put a system action on a keyboard shortcut, a Siri voice command, or an automation.

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
silently ignored. No error, no alert.

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
| Open Rosetta Stone | `rosettastone://open-app` | Menu-bar app, no Dock icon — this is your launcher |
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
| Background execution | An action triggered while the app is closed launches it in the background — **no window appears**. That is intentional. The action is queued and runs as soon as the app finishes starting, so a cold start works exactly like a warm one. |
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
| No menu-bar icon after launch | Open **Diagnostics…** (§5). If the status item reports a width of 0 the icon failed to render; if it reports "missing (never created)" the app did not finish launching. |
| Nothing at all appears on first launch | The app opens its panel once on first run — that is deliberate (§4.4). If it did not, check **Diagnostics…**. |
| App does not start at login | Toggle **Run at Startup** off, then on again, then log out and back in. **Diagnostics…** shows whether the login item is installed and whether it is stale. |
| A Shortcut did nothing | Confirm the app is allowed to run at all (§4). Actions that are already running in the background perform silently — see §9.7. |
| Password prompt never appears | Check that a previous `osascript` dialog is not hidden behind another window. Only one privileged action runs at a time. |
| "Operation not permitted" | You cancelled the prompt, or the command needs root and did not get it. Retry and complete the password prompt. |
| Rosetta 2 install fails | You need an internet connection. On macOS 11.0–11.2 the component is not bundled; update to 11.3+ first. |
| Auto Boot toggle is greyed | You are on Apple Silicon — this setting does not exist there. |
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



