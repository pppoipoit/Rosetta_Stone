# Rosetta Stone macOS App — Comprehensive Handover Document

> **Purpose:** This file captures the **exact current state** of the Rosetta Stone macOS app so that an AI agent (or any future developer) can consult it without needing to ask the owner for basic context. It is intentionally dense and technically precise.

---

## 1. Project Overview

| Item | Details |
|------|---------|
| **App Name** | Rosetta Stone |
| **Tech Stack** | SwiftUI + AppKit, Swift 5+, macOS 10.15+ (deployment floor 10.15) |
| **Primary Distribution** | Downloadable DMG for Intel & Apple Silicon Macs |
| **Core Philosophy** | Three pillars govern every line of behavior:<br>1. **Deferred Queue** — all state-changing actions go through a staged `PendingChange` queue; the two master buttons (**OK / CANCEL**) commit or discard the entire batch with a **single** Authorization dialog.<br>2. **Single-Auth Batching** — `SystemCommands.runBatched()` packs admin commands into one `osascript -e` invocation, so the user sees exactly one password prompt for the whole session.<br>3. **Truth-First State Sync** — after every terminal state (success, cancellation, failure) the coordinator calls `reloadState()` to re-read the real system state, overriding any optimistic UI updates. This prevents MDM or spontaneous re-enforcement from leaving the UI out of sync. |

---

## 2. Architecture & Key Components

### 2.1 Deferred Queue & Master Apply (ADR-009)

| Concept | Description |
|---------|-------------|
| `PendingChange` enum | `Models/DeferredChange.swift` — the queue holds zero or more `PendingChange` values keyed by `FeatureID`. A toggle flip writes **here** only; no command runs. The two master buttons (`applyPendingChanges()` / `cancelPendingChanges()`) are the only things that trigger privileged work. |
| `FeatureCommand` struct | `Models/DeferredChange.swift` — each pending change is converted into a `FeatureCommand` carrying: `.work` (`.shell` or `.inline`), `requiresAdmin: Bool`, `timeout`, optional `batchPostStep`, and `marker` from `FeatureID.rawValue` for exact batch-result parsing. |
| `BatchReport` / `BatchItemResult` | One report per batch commit. `BatchReport.id` is deterministic (`feature:success|failure`). `wasCancelled` is true when the user dismissed the Authorization dialog — **not** an error per `docs/FEATURES.md`. |
| Master buttons | **OK** → `applyBatch` → one `osascript` prompt, then `reloadState()`. **CANCEL** → discards queue and re-reads reality. |

---

### 2.2 Single-Auth Batching (`Services/SystemCommands.swift`)

| Mechanism | Detail |
|-----------|--------|
| `runBatched(_:)` | Builds single AppleScript: `do shell script "...; ..." with administrator privileges`. One `osascript` invocation, one Authorization prompt. |
| `runAsAdmin(_:timeout:)` | Lower-level helper for batch builder and immediate routes. Returns `CommandOutcome`. |
| Gatekeeper two-step (macOS 15+) | `gatekeeperDisableRequiresSystemSettingsConfirmation` returns true when majorVersion >= 15. Runs `spctl --master-disable`, then opens `x-apple.systempreferences:com.apple.preference.security` deep-link. UI shows `.pendingConfirmation` and polls until user clicks **Anywhere**. App cannot automate the click. |
| Exit-code-agnostic parsing | After any write, coordinator always re-reads via `SystemStateReader`. Never trusts exit code. |

---

### 2.3 Mini App Mode (Phase 11)

| Aspect | Description |
|--------|-------------|
| **Mode B** (Run at Startup ON) | Launches hidden: no Dock tile, no window. Menu-bar status item always present. Left-click opens **Mini App** (`MiniAppView.swift`) — small `NSPanel` with 3 switches (Gatekeeper, Hidden Files, Run at Startup), OK/CANCEL bar, same deferred-queue semantics. Right-click opens full menu (Open Window, toggles, Diagnostics, Quit). |
| `Cmd+W` | `AppDelegate.hideMainWindow()` — hides main panel to menu bar. App stays alive in both modes. |
| `Cmd+Q` | Installed in main menu (Phase 11). `MenuBarController.quit()` terminates cleanly. |
| `NSPanel` | Both panels are `NSWindow` instances owned by `MenuBarController`. `isReleasedWhenClosed = false` preserves coordinator state. |
| Mini panel rows | Only three: Gatekeeper, Hidden Files, Run at Startup. Auto Boot and Rosetta excluded. |

---

### 2.4 Truth-First Sync Triggers

| Trigger | What happens |
|---------|--------------|
| Launch | `AppDelegate.init()` reads LaunchAgent plist, resolves `AppMode`. `loadState("launch")` populates `@Published` values. |
| `didBecomeActive` | App delegate calls `loadState("active")` to sync external changes. |
| After Apply/Cancel | `finish()` always ends with `reloadState()` — re-reads `spctl`, `defaults`, `nvram`. |

---

## 3. Current Status (Phase 11.4.4)

### 3.1 Fully Implemented & Working

- **URL scheme removed** — no `handlesExternalEvents`/`onOpenURL` in `RosettaStoneApp.swift`
- **Gatekeeper mapping locked** — `ON`→`spctl --master-enable`, `OFF`→`spctl --master-disable`; `GatekeeperState` machine tracks `.active`/`.pendingConfirmation`/`.bypassed`/`.unknown`
- **Exit-code-agnostic parser** — `parseSpctlStatus()` and `areHiddenFilesShown()` parse stdout text; exit code ignored
- **Deferred queue** — OK/CANCEL batch whole queue into one `osascript` prompt; `wasCancelled` honoured
- **Mini App mode** — left-click mini panel, right-click menu, Cmd+W/Cmd+Q
- **Run-at-Startup mode switch** — `AppMode.resolve()` via `--menu-bar-only`; Mode A/B switch at runtime
- **Diagnostics panel** — hardware, OS, status-item, LaunchAgent status
- **Status-item toast** — for direct actions in Mode B
- **TooltipHost bridge fix** (Phase 11.4.4) — `NSHostingView.rootView` is now updated in `updateNSView`, so rows wrapped for AppKit tooltips (Gatekeeper, Auto Boot, mini-panel Gatekeeper) repaint after state changes. The `.id(UUID())` debug workaround is removed.
- **Hidden Files verification** (Phase 11.4.4) — post-refresh read-back now compares `AppleShowAllFiles` against the requested direction (`shown`), not just truthiness, so hiding files no longer reads as a failure.
- **Unified logging** (Phase 11.4.4) — `Trace` writes to both `NSLog` and `os_log` with subsystem `com.rosettastone.app` and categories `lifecycle` / `batch`; `[RS-BATCH]` remains in the message text for filtering.
- **Batch marker exact match** (Phase 11.4.4) — `RS_FAIL:<marker>` now uses exact `==` match, the same rule as `RS_OK:<marker>`, so one row can never be mistaken for another.

---

### 3.2 Resolved Issues (previously the CRITICAL SECTION)

> All four items that were in this section are now resolved as of Phase 11.4.4. The original
> descriptions are retained in §4 below for historical context.

| Area | Resolution | Phase |
|------|------------|-------|
| UI Toggle Animation | `TooltipHost.updateNSView` now sets `hosting.rootView = content`; debug `.id(UUID())` and `objectWillChange.send()` removed. | 11.4.4 |
| Finder Refresh | Verification now compares read-back against the requested `shown` value via `parseDefaultsBool`. | 11.4.4 |
| Missing `[RS-BATCH]` logs | `Trace.batch` now writes to `os_log` (subsystem `com.rosettastone.app`, category `batch`) in addition to `NSLog`. | 11.4.4 |
| Gatekeeper 2-step macOS 15+ | Confirmed working by owner on macOS 15+. | 11.4.4 |

---

## 4. Known Issues & Bugs (The "Why" of Current Failures)

All four issues below are **historical** — each was resolved in Phase 11.4.4 and is
retained only as the original root-cause record. See §3.2 for the resolution summary.

| # | Issue | Root Cause (suspected) | Impact | Work-Around / Next Step | Resolution |
|---|-------|------------------------|--------|--------------------------|------------|
| 1 | **UI Toggle Animation not sliding** | Possible `@Binding` mismatch or missing `.id()` identifier on `PillSwitch`. Backend `@Published` value changes, but SwiftUI view does not re-evaluate its animation. | Switch "flips" logically but visual track does not animate. | Inspect `PillSwitch` component. Add explicit `.id(feature.rawValue)` on row view. | **Fixed 11.4.4.** `TooltipHost.updateNSView` now sets `hosting.rootView = content`; `.id(UUID())` and `objectWillChange.send()` removed. |
| 2 | **Finder refresh -1708 error** | AppleScript `update every window` returns error `-1708` ("User canceled") on macOS 14.7.4 when no Finder windows are open or non-interactive context. 3-step fallback may have AppleScript step failing silently. | Hidden Files toggle reports success but Finder windows may not reflect change. | Verify AppleScript only runs when Finder windows exist. Replace with `defaults write` + `killall Finder`. | **Fixed 11.4.4.** Verification now reads back `AppleShowAllFiles` and compares against the requested value via `parseDefaultsBool`. |
| 3 | **`[RS-BATCH]` traces not in Console.app** | `Trace.batch()` uses `NSLog`. On some macOS versions output may route to `system.log` instead of Console filter, or process lacks entitlement. | Cannot grep `[RS-BATCH]` for batch diagnostics. | Switch to `os_log` (macOS 11+) or file-based logging. Add compile-time flag. | **Fixed 11.4.4.** `Trace.batch` now writes to `os_log` (subsystem `com.rosettastone.app`) in addition to `NSLog`. |
| 4 | **Gatekeeper 2-step doesn't auto-complete macOS 15+** | Deep link may not bring Security page to foreground on all macOS 15 builds. If System Settings is hidden, state never settles. | UI stuck in `.pendingConfirmation` indefinitely. | Add `NSWorkspace.open` + bounded re-poll loop. Document: app **cannot** automate "Anywhere" click. | **Confirmed working** by owner on macOS 15+. |

---

## 5. Environment & CI/CD Constraints (STRICT RULES FOR NEXT AI)

| Rule | Detail |
|------|--------|
| Host environment | AI agents run on **Windows**. No local `xcodebuild`, no macOS SDK, no simulated macOS filesystem. |
| Validation pathway | GitHub Actions (`workflow_dispatch`) for CI. Manual testing on owner's Intel Mac (macOS 14.7.4) and Apple Silicon Mac (macOS 26 Tahoe). |
| No guessing | If code is needed, ask the owner to paste the relevant snippet. Do not infer or guess. |
| Build-or-run assumptions | Do **not** assume `xcodebuild` works on Windows. Builds must run on owner's Mac or remote GitHub runner with SDK. |
| Documentation-first | All behaviour must be recorded in `HANDOVER.md` before any code change is "complete". |

---

## 6. File Structure & Key Files (Brief Map)

| Path | Role |
|------|------|
| `RosettaStone/AppDelegate.swift` | Application delegate — mode resolution, main/mini panel control, Cmd+W/Cmd+Q, menu installation. |
| `RosettaStone/RosettaStoneApp.swift` | SwiftUI `App` entry (macOS 11+). Delegates to `AppDelegate`. No URL-scheme handling. |
| `RosettaStone/Models/FeatureID.swift` | Eight `FeatureID` cases. `rawValue` is the batch marker. `requiresElevation` property. |
| `RosettaStone/Models/DeferredChange.swift` | `PendingChange` enum and `FeatureCommand` / `BatchReport` types. Deferred queue staging area. |
| `RosettaStone/Services/SystemCommands.swift` | Core elevation choke point. `runBatched()`, `runAsAdmin()`, `runShell()`, `run()`. Gatekeeper two-step helpers. |
| `RosettaStone/Services/FeatureCoordinator.swift` | Single source of truth for panel state. `@Published` values, serial queue, `applyBatch`, `finish` (calls `reloadState`). |
| `RosettaStone/Services/FeatureCoordinator+Actions.swift` | Eight feature methods: toggleRunAtStartup, toggleGatekeeper, toggleHiddenFiles, toggleAutoBoot, installRosetta, rebuildSpotlight, flushDNS, clearSystemCache. |
| `RosettaStone/Services/GatekeeperPolicy.swift` | `GatekeeperState` enum (.active, .pendingConfirmation, .bypassed, .unknown). Deep-link and messages. Two-step logic for macOS 15+. |
| `RosettaStone/Services/SystemStateReader.swift` | Unprivileged reads: `isGatekeeperBypassed()`, `areHiddenFilesShown()`, `isAutoBootEnabled()`, `isRosettaInstalled()`. Exit-code-agnostic. |
| `RosettaStone/Services/Trace.swift` | `Trace.log()` and `Trace.batch("[RS-BATCH] …")`. `batchPrefix`, `escaped()`, `logLaunchContext()`, `osVersionText()`. |
| `RosettaStone/Models/CommandResult.swift` | `ProcessResult` and `CommandOutcome` (success/cancelled/failure). |
| `RosettaStone/Models/AppMode.swift` | `AppMode` enum (.normal, .menuBarGadget). Resolution: `--menu-bar-only` flag → gadget. |
| `RosettaStone/Services/StartupManager.swift` | Installs/removes `~/Library/LaunchAgents/com.rosettastone.helper.plist`. |
| `RosettaStone/Services/MacProfile.swift` | `MacFormFactor`. Gating for Auto Boot — requires Intel + laptop. |
| `RosettaStone/Services/CPUArchitecture.swift` | `CPUArchitecture` (arm64, x86_64, unknown). `supportsRosettaInstall` = .arm64. |
| `RosettaStone/Views/Main/ContentView.swift` | Main dark panel — row order, pending-dot, Apply/Cancel bar, batch-results sheet. |
| `RosettaStone/Views/Main/Theme.swift` | Colours, gradients, pill styles, metrics. |
| `RosettaStone/Views/Main/Components.swift` | Reusable: `PillSwitch`, `PendingPillSwitch`, `TooltipHost`, `LockIcon`. |
| `RosettaStone/Views/MenuBar/MiniAppView.swift` | Mini-panel with 3 switches, OK/CANCEL, same deferred-queue semantics. |
| `RosettaStone/Views/MenuBar/MenuBarController.swift` | Owns status item, main window, mini panel. Keyboard shortcuts, menu construction. |
| `RosettaStone/Views/MenuBar/DiagnosticsPanel.swift` | Remote-debugging lifeline — hardware, OS, and LaunchAgent status. |
| `RosettaStone/Views/MenuBar/StatusItemToast.swift` | Transient HUD under the status item. |
| `docs/ARCHITECTURE.md` | Authority for layering rules, elevation policies, design rationale. |
| `docs/FEATURES.md` | Feature-by-feature expectations, feedback conventions, known behaviours. |

---

## 7. Recent Git History (last 10 commits)

| Hash | Message |
|------|---------|
| afd5a70 | fix: Phase 11.4.4 — Live tooltip rows, exact batch parsing, unified logging |
| daa2550 | docs: add comprehensive HANDOVER.md for AI consultation |
| a69ee83 | fix: Phase 11.4.3 — force UI re-render with .id(UUID()), add debug logs and post-refresh verification |
| 971df3b | fix: Phase 11.4 — truth-first state sync, gatekeeper mapping, Finder refresh chain; remove URL-scheme shortcuts and status dot |
| 7d27ffd | fix: build error — NSAppleScript.executeAndReturnError returns non-optional |
| 3dbd52c | chore: add batch diagnostics logging (no behaviour change) |
| 6411358 | fix: Window menu bound Cmd-M twice (Minimize and Mini Panel) |
| 2eec0f3 | tools: add scripts/audit_scope.py |
| fe55de  | fix: MiniAppView rows/footer/commitBar landed inside body's VStack |
| ba84e7d | feat: UI/UX overhaul + mini app mode + deferred queue |
| fd55f97 | docs+app: fix ADR-010 cross-ref and complete Info.plist attribution |
| 1d26ec4 | docs: complete CC BY-SA 3.0 attribution |

---

## 8. Commit & Push Instructions

Once reviewed by the owner, commit this document:

```bash
git add docs/HANDOVER.md
git commit -m "docs: add comprehensive HANDOVER.md for AI consultation"
git push origin main
```

---

*End of HANDOVER.md*