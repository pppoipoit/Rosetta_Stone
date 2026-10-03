import SwiftUI
import AppKit

/// The dark-mode feature panel — the app's only window.
///
/// ## Row order (fixed, from `docs/FEATURES.md` "Row order")
/// 1. Run at Startup · 2. Gatekeeper · 3. Hidden Files · 4. Auto Boot ·
/// 5. Rosetta 2 · 6. Quick Tools (Spotlight / DNS / Cache)
///
/// ## Hardware gating
/// Two rows are gated on the cached `MacProfile` (ADR-008):
/// - **Auto Boot** is greyed with a 🔒 unless the machine is an **Intel MacBook** — Apple
///   Silicon firmware owns the variable, and a desktop has no lid to open. The subtitle and
///   the hover tooltip both come from `MacProfile.autoBootDisabledReason`.
/// - **Rosetta 2** is greyed with a 🔒 on `x86_64` — Rosetta is an Apple Silicon feature.
///   (Architectural only: `profile.cpuArchitecture`, never the form factor.)
///
/// Both are **greyed out, never hidden**, so the panel looks the same on every machine and
/// the padlock explains the absence instead of making the feature look missing.
///
/// The view observes `FeatureCoordinator` and never spawns a process itself — layering
/// rule 1 of `docs/ARCHITECTURE.md` §6.
struct ContentView: View {

    /// Window size, also used by `MenuBarController` when creating the `NSWindow`.
    ///
    /// Height grew from 540 when the Apply/Cancel bar was added (Phase 9). The rows are laid
    /// out between two `Spacer`s, so the extra height is absorbed by the flexible space rather
    /// than by cropping content — no row was removed or shrunk to make room.
    static let panelWidth: CGFloat = 460
    static let panelHeight: CGFloat = 600

    @ObservedObject var coordinator: FeatureCoordinator

    /// Opens the Diagnostics panel. Provided by `MenuBarController`.
    ///
    /// Mode A has no menu-bar icon, so this footer link is the only route to the
    /// diagnostics report there; in mode B the same panel is also in the right-click menu.
    let onShowDiagnostics: (() -> Void)?

    /// A pending confirmation, presented as a sheet.
    @State private var pendingConfirmation: ConfirmationRequest?

    /// Changes staged but **not yet applied** (ADR-009).
    ///
    /// The panel is a staging area: a toggle writes here and nothing else. Committing happens
    /// exclusively through `applyPendingChanges()`, which hands the whole queue to
    /// `FeatureCoordinator.applyBatch` — one Authorization dialog for the lot.
    ///
    /// Keyed by `FeatureID`, so a row can hold at most one staged change: toggling a row twice
    /// before applying replaces the earlier intent instead of queueing it twice.
    @State private var pendingChanges: [FeatureID: PendingChange] = [:]

    /// Per-item batch results awaiting display. Non-nil only after a batch that had a failure.
    @State private var batchReport: BatchReport?

    /// A destructive or long-running action awaiting explicit confirmation.
    struct ConfirmationRequest: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        let confirmTitle: String
        /// `true` renders the dialog with a critical (red) style.
        let isDestructive: Bool
        let action: () -> Void
    }

    var body: some View {
        VStack(spacing: 0) {
            background
            content
        }
        .frame(width: ContentView.panelWidth, height: ContentView.panelHeight)
        .sheet(item: $pendingConfirmation) { request in
            ConfirmationSheet(request: request) { confirmed in
                if confirmed { request.action() }
                pendingConfirmation = nil
            }
        }
        .sheet(item: $batchReport) { report in
            BatchReportSheet(report: report) { batchReport = nil }
        }
    }

    // MARK: - Chrome

    /// The dark gradient behind the transparent titlebar, drawn edge to edge.
    private var background: some View {
        LinearGradient(gradient: Gradient(colors: [Theme.backgroundTop, Theme.backgroundBottom]),
                       startPoint: .top,
                       endPoint: .bottom)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var content: some View {
        VStack(spacing: 0) {
            header
            Spacer(minLength: 0)
            rows
            Spacer(minLength: 0)
            footer
            // The master buttons sit *below* the status banner, so the last thing the eye
            // lands on before ⌘↩ is the commit action itself.
            ApplyBar(pendingCount: pendingChanges.count,
                     isBusy: coordinator.isBusy,
                     onCancel: cancelPendingChanges,
                     onApply: applyPendingChanges)
        }
        .padding(.top, 26)
        .padding(.bottom, 16)
        .padding(.horizontal, Theme.contentPadding)
    }

    /// Centred title plus the detected hardware, so the locked rows have context.
    ///
    /// The subtitle reads e.g. `macOS 15.4 · Intel · Laptop` — the architecture **and** the
    /// form factor. The Auto Boot lock now depends on both, so an architecture-only caption
    /// would be actively misleading on an Intel Mac mini, whose Auto Boot row is locked.
    private var header: some View {
        VStack(spacing: 4) {
            Text("Rosetta Stone")
                .font(.system(size: 21, weight: .bold))
                .foregroundColor(Theme.title)
            Text("macOS \(ContentView.osVersionText) · \(coordinator.architecture.displayName)"
               + " · \(coordinator.profile.formFactor.displayName)")
                .font(.system(size: 11))
                .foregroundColor(Theme.secondaryText)
        }
    }

    /// Formatted as "15.4", not the default struct dump.
    ///
    /// `OperatingSystemVersion` does not conform to `CustomStringConvertible`, so
    /// interpolating it directly would render
    /// `Version(majorVersion: 15, minorVersion: 4, patchVersion: 0)` in the panel.
    private static var osVersionText: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return version.patchVersion == 0
            ? "\(version.majorVersion).\(version.minorVersion)"
            : "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    private var footer: some View {
        VStack(spacing: 8) {
            if let warning = coordinator.warning {
                StatusBanner(message: FeatureCoordinator.StatusMessage(text: warning, style: .info))
            }
            if let status = coordinator.statusMessage {
                StatusBanner(message: status)
            }
            HStack(spacing: 6) {
                Text("Version \(MenuBarController.versionString)")
                    .font(.system(size: 10))
                    .foregroundColor(Theme.secondaryText.opacity(0.7))

                Spacer(minLength: 0)

                // Reachable in **both** modes: mode A has no menu-bar icon, so this is
                // the only way to the diagnostics report there.
                Button("Diagnostics…") { onShowDiagnostics?() }
                    .buttonStyle(QuietLinkButtonStyle())
                    .disabled(coordinator.isBusy)
            }
        }
        .padding(.top, 12)
    }

    // MARK: - Rows

    /// The five feature rows, in the fixed order, plus the Quick Tools grid.
    private var rows: some View {
        VStack(spacing: 0) {
            // 1. Run at Startup — admin
            toggleRow(feature: .runAtStartup)
            RowSeparator()

            // 2. Gatekeeper — admin, INVERTED: ON == bypassed (less secure)
            toggleRow(feature: .gatekeeper)
            RowSeparator()

            // 3. Hidden Files — no elevation, INVERTED: ON == hidden files shown
            toggleRow(feature: .hiddenFiles)
            RowSeparator()

            // 4. Auto Boot — admin, **Intel MacBook only**. Greyed + 🔒 wherever the profile says the
            // setting is meaningless: Apple Silicon (firmware owns `AutoBoot`, NVRAM reset
            // every cold boot) and desktops (no lid). Both the subtitle and the hover tooltip
            // come from `MacProfile.autoBootDisabledReason`, so a greyed row always explains
            // itself. The row stays wrapped in `TooltipHost` because a `.disabled(true)` row
            // cannot show a SwiftUI `.help(_:)` — that is macOS 11+ and this app is 10.15.
            TooltipHost(
                text: lockedTooltip(for: .autoBoot),
                content: toggleRow(feature: .autoBoot)
            )
            RowSeparator()

            // 5. Rosetta 2 — admin, Apple Silicon only. Disabled + lock on x86_64.
            rosettaRow
            RowSeparator()

            // 6. Quick Tools
            quickTools
        }
    }

    /// Tooltip text for a row: the owner-specified copy when a lock carries one, else the
    /// English lock reason. Empty for an interactive row, which therefore shows no tooltip.
    ///
    /// For the Auto Boot row both the subtitle and this tooltip come from
    /// `MacProfile.autoBootDisabledReason`, which is non-nil whenever the row is locked — so
    /// the fallback to `lockReason` is belt-and-braces, never the path taken.
    private func lockedTooltip(for feature: FeatureID) -> String {
        let availability = coordinator.availability(for: feature)
        guard availability.isEnabled == false else { return "" }
        return availability.tooltip ?? availability.lockReason ?? ""
    }

    /// A toggle row: title, one-line detail, the pending dot, and the pill switch.
    ///
    /// The row is a `Button` rather than a `Toggle` so the whole row is one hit target
    /// and the app controls its own switch rendering (see `PillSwitch`). `.disabled(...)`
    /// covers three cases at once: the row is CPU-locked, its own command is in flight, or
    /// *any* command is in flight. When locked the label is greyed via `opacity` and the
    /// reason replaces the usual description in the subtitle.
    ///
    /// ## Pending state (ADR-009)
    ///
    /// The pill shows the **staged** value, not the applied one — the user must see what they
    /// asked for. The orange dot beside the title is what distinguishes the two: it appears
    /// exactly when `pending != actual`, so a glance answers "what will change on Apply?"
    /// without applying anything.
    private func toggleRow(feature: FeatureID) -> some View {
        let availability = coordinator.availability(for: feature)
        let isBusy = coordinator.busyFeature == feature
        let isInteractive = availability.isEnabled && coordinator.isBusy == false

        let actual = actualValue(for: feature)
        let staged = stagedValue(for: feature, actual: actual)
        let isPending = pendingChanges[feature] != nil

        return Button {
            // Stages the opposite of what the pill currently shows. Deriving from the
            // *staged* value (falling back to actual) is what makes a second tap before
            // Apply flip the row back rather than trying to stage the same value twice.
            let next = !staged
            // Auto Boot is the one toggle that cannot simply stage: it writes firmware NVRAM
            // that survives reboots, reinstalls and upgrades, so it keeps its confirmation
            // sheet — raised at **stage time**, before anything is committed (ADR-009).
            if feature == .autoBoot {
                confirmAutoBoot(enabled: next)
            } else {
                stageToggle(feature, newValue: next)
            }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(feature.title)
                            .font(.system(size: 15, weight: .regular))
                            .foregroundColor(availability.isEnabled ? Theme.primaryText : Theme.secondaryText)
                        // Staged, but not yet applied. Hidden on a locked row: there is
                        // nothing to stage on a row the user cannot operate.
                        if isPending && availability.isEnabled {
                            PendingDot()
                        }
                    }
                    Text(availability.lockReason ?? feature.detail)
                        .font(.system(size: 11))
                        .foregroundColor(Theme.secondaryText.opacity(0.85))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                // The padlock replaces the switch when the row is unavailable; the
                // spinner replaces it while the row's command is in flight.
                if availability.isEnabled == false {
                    LockIcon()
                } else if isBusy {
                    BusySpinner()
                } else {
                    PillSwitch(isOn: staged)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(isInteractive == false)
        .opacity(availability.isEnabled ? 1 : 0.45)
        .frame(minHeight: Theme.rowSpacing * 1.7)
    }

/// Feature 5 — the Install button.
    ///
    /// Every state keeps a control in the same place so the panel does not reflow, and
    /// each state is driven by real state rather than a guess:
    /// - **locked** (x86_64): the yellow "Install" button is rendered but **disabled**,
    ///   next to a 🔒. Omitting the button would make the panel jump and would read as
    ///   "this feature is missing" rather than "this Mac cannot use it" (FEATURES.md §5).
    /// - **installed**: a disabled "Installed" chip, so no password prompt is ever offered,
    /// - **available**: the live yellow "Install" button from the mock-up.
    private var rosettaRow: some View {
        let availability = coordinator.availability(for: .rosetta2)
        let isBusy = coordinator.busyFeature == .rosetta2
        let isQueued = pendingChanges[.rosetta2] != nil

        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(FeatureID.rosetta2.title)
                        .font(.system(size: 15, weight: .regular))
                        .foregroundColor(availability.isEnabled ? Theme.primaryText : Theme.secondaryText)
                    if isQueued && availability.isEnabled {
                        PendingDot()
                    }
                }
                Text(availability.lockReason ?? FeatureID.rosetta2.detail)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.secondaryText.opacity(0.85))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            // The padlock is independent of the control, so a locked row keeps its
            // button in place rather than reflowing the panel.
            if availability.isEnabled == false {
                LockIcon()
            }

            if coordinator.rosettaInstalled {
                Text("Installed")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.secondaryText)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Theme.buttonBorder, lineWidth: 1)
                    )
            } else if isBusy {
                // `softwareupdate` takes minutes: show progress, never a frozen window.
                HStack(spacing: 8) {
                    BusySpinner(size: 16)
                    Text("Installing…")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.primaryText)
                }
            } else {
                // Rendered in every state; only `isEnabled` differs. On Intel the button
                // is inert, so the row can never raise an Authorization dialog.
                // The "may take several minutes" warning is raised **at stage time**
                // (ADR-009): the user is told what they are queuing, before the
                // password prompt, not after it.
                Button(isQueued ? "Queued" : "Install") { confirmRosettaInstall() }
                    .buttonStyle(AccentButtonStyle())
                    .disabled(coordinator.isBusy || availability.isEnabled == false)
            }
        }
        .opacity(availability.isEnabled ? 1 : 0.45)
        .frame(minHeight: Theme.rowSpacing * 1.9)
    }

    /// Features 6, 7 and 8 — the one-shot maintenance buttons.
    ///
    /// Each stages rather than runs (ADR-009), and each disables itself while *any* operation
    /// is in flight, so only one Authorization dialog can ever be on screen.
    private var quickTools: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Quick Tools")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Theme.primaryText)
                .padding(.top, 16)

            HStack(spacing: 10) {
                quickToolButton(title: "Spotlight",
                                feature: .spotlightRebuild,
                                busy: coordinator.busyFeature == .spotlightRebuild,
                                action: confirmSpotlightRebuild)
                quickToolButton(title: "DNS",
                                feature: .dnsFlush,
                                busy: coordinator.busyFeature == .dnsFlush,
                                action: confirmDNSFlush)
                quickToolButton(title: "Cache",
                                feature: .clearSystemCache,
                                busy: coordinator.busyFeature == .clearSystemCache,
                                action: confirmClearCache)
            }
        }
    }

    /// One Quick Tool button. `feature` identifies the row so the button can show its own
    /// queued state — an orange dot inline, without needing a separate row title.
    private func quickToolButton(title: String,
                                feature: FeatureID,
                                busy: Bool,
                                action: @escaping () -> Void) -> some View {
        let isQueued = pendingChanges[feature] != nil
        return Button(action: action) {
            HStack(spacing: 6) {
                if busy {
                    BusySpinner(size: 12)
                } else if isQueued {
                    PendingDot(size: 6)
                }
                Text(isQueued ? "\(title) · queued" : title)
            }
        }
        .buttonStyle(QuickToolButtonStyle())
        .disabled(coordinator.isBusy)
    }

    // MARK: - Confirmations
    //
    // Four actions must be confirmed in-app *in addition to* the macOS Authorization
    // dialog: Auto Boot (permanent NVRAM), Rosetta 2 (minutes, needs a licence agreement),
    // Spotlight Rebuild (heavy I/O), DNS Flush (brief network blip) and Clear System Cache
    // (destructive, no undo). The confirmation is never a substitute for the auth prompt.

    /// Feature 4 — NVRAM writes survive reboots, reinstalls and OS upgrades, and are not
    /// safely reversible if interrupted.
    private func confirmAutoBoot(enabled: Bool) {
        pendingConfirmation = ConfirmationRequest(
            title: enabled ? "Enable auto boot?" : "Disable auto boot?",
            message: "This writes the firmware AutoBoot setting, which persists across reboots, "
                + "macOS reinstalls and upgrades. If the write is interrupted the Mac may not "
                + "power on automatically until you set it again.",
            confirmTitle: enabled ? "Enable" : "Disable",
            isDestructive: !enabled
        ) {
            stageToggle(.autoBoot, newValue: enabled)
        }
    }

    /// Feature 5 — multi-minute download that accepts the Rosetta licence agreement.
    private func confirmRosettaInstall() {
        pendingConfirmation = ConfirmationRequest(
            title: "Install Rosetta 2?",
            message: "This downloads and installs Apple's translation layer so Intel-only apps "
                + "can run on Apple Silicon. It can take several minutes and needs a network "
                + "connection. Apple’s licence is accepted on your behalf.",
            confirmTitle: "Install",
            isDestructive: false
        ) {
            stageAction(.rosetta2)
        }
    }

    /// Feature 6 — the rebuild continues for minutes after the command returns.
    private func confirmSpotlightRebuild() {
        pendingConfirmation = ConfirmationRequest(
            title: "Rebuild the Spotlight index?",
            message: "Spotlight will discard its index for the startup volume and rebuild it "
                + "from scratch. Search will be incomplete for several minutes and the Mac "
                + "will be busy while it works.",
            confirmTitle: "Rebuild",
            isDestructive: false
        ) {
            stageAction(.spotlightRebuild)
        }
    }

    /// Feature 7 — `killall -HUP mDNSResponder` drops connections for under a second.
    private func confirmDNSFlush() {
        pendingConfirmation = ConfirmationRequest(
            title: "Flush the DNS cache?",
            message: "The resolver cache is cleared and mDNSResponder restarts. Your network "
                + "will blip for a moment — active downloads and VPN sessions may drop and "
                + "reconnect.",
            confirmTitle: "Flush",
            isDestructive: false
        ) {
            stageAction(.dnsFlush)
        }
    }

    /// Feature 8 — the highest-risk action in the app. Confirmation **and** auth prompt.
    /// The warning copy is shared with the status-item menu and the URL scheme
    /// (`FeatureID.clearSystemCacheWarning`) so the three can never disagree about the risk.
    private func confirmClearCache() {
        pendingConfirmation = ConfirmationRequest(
            title: "Clear the system cache?",
            message: FeatureID.clearSystemCacheWarning,
            confirmTitle: "Clear Cache",
            isDestructive: true
        ) {
            stageAction(.clearSystemCache)
        }
    }

    // MARK: - The deferred queue (ADR-009)
    //
    // Four operations, and the invariants they hold:
    //
    // | Operation          | Meaning                                                  |
    // |--------------------|----------------------------------------------------------|
    // | `stageToggle`      | record a desired boolean; **removes** the entry if it equals the actual value |
    // | `stageAction`      | record a one-shot action                                    |
    // | `applyPendingChanges` | commit the whole queue in one batch, in **row order**      |
    // | `cancelPendingChanges` | discard the queue without touching the system           |
    //
    // Nothing else mutates `pendingChanges`.

    /// The value the system currently reports for a row, in the row's own ON/OFF semantics.
    ///
    /// `nil` is a real answer for Gatekeeper and Auto Boot — "could not read" is not "OFF"
    /// (`docs/FEATURES.md` §2, §4) — so it falls back to `false` only for display. The pending
    /// dot is unaffected: a staged value that happens to match the fallback still shows, and
    /// only a failed batch clears it.
    private func actualValue(for feature: FeatureID) -> Bool {
        switch feature {
        case .runAtStartup: return coordinator.runAtStartup
        case .gatekeeper:   return coordinator.gatekeeperBypassed ?? false
        case .hiddenFiles:  return coordinator.hiddenFilesShown
        case .autoBoot:     return coordinator.autoBootEnabled ?? false
        default:            return false
        }
    }

    /// What the pill should display: the staged value if there is one, else the real one.
    ///
    /// Showing the staged value is the whole point of a deferred queue — the user must see
    /// what they asked for before committing to a password prompt.
    private func stagedValue(for feature: FeatureID, actual: Bool) -> Bool {
        if case .toggle(let value)? = pendingChanges[feature] { return value }
        return actual
    }

    /// Records a desired toggle value.
    ///
    /// Staging a value that **equals the actual state** removes the entry instead of storing
    /// it. Without that, tapping a switch on and then off would leave a permanent pending dot
    /// for a change that does not exist — and the dot is defined as "pending ≠ actual", so an
    /// entry equal to actual is not pending by definition.
    private func stageToggle(_ feature: FeatureID, newValue: Bool) {
        guard newValue != actualValue(for: feature) else {
            pendingChanges.removeValue(forKey: feature)
            return
        }
        pendingChanges[feature] = .toggle(newValue)
    }

    /// Records a one-shot action. Re-pressing an already-queued row is a no-op, not a toggle
    /// off: unlike a switch there is no "value" to flip back, and cancelling the queue is
    /// what the master Cancel button is for.
    private func stageAction(_ feature: FeatureID) {
        pendingChanges[feature] = .action
    }

    /// Commits the whole queue: **one** Authorization dialog for every privileged row.
    ///
    /// Commands are built in `FeatureID.allCases` order, so the batch always runs in the
    /// fixed row order the panel displays, regardless of the order the user tapped. It also
    /// means the results dialog reads in the same order as the panel.
    private func applyPendingChanges() {
        guard pendingChanges.isEmpty == false, coordinator.isBusy == false else { return }

        let commands = FeatureID.allCases.compactMap { feature -> FeatureCommand? in
            guard let pending = pendingChanges[feature] else { return nil }
            return coordinator.command(for: feature, pending: pending)
        }

        guard commands.isEmpty == false else {
            // Every staged change was a no-op (e.g. Rosetta already installed). Nothing to
            // run, so drop the queue rather than leaving undotable rows behind.
            pendingChanges.removeAll()
            return
        }

        coordinator.applyBatch(commands) { [weak self] report in
            guard let self = self else { return }
            // Cleared here rather than optimistically at the press, so a **cancelled** batch
            // leaves the queue intact and the user can simply press Apply again. Entries whose
            // command never made it into the batch (already satisfied) are dropped, because
            // they can never become runnable.
            if report.wasCancelled {
                return
            }
            self.pendingChanges = self.pendingChanges.filter { feature, _ in
                report.outcome(for: feature) != nil
            }
            // A per-item dialog is raised only when something actually failed; the all-success
            // case is already covered by the footer banner.
            if report.allSucceeded == false {
                self.batchReport = report
            }
        }
    }

    /// Discards the queue. Touches nothing in the system: no command ran, so no confirmation
    /// is warranted — this is a pure UI reset.
    private func cancelPendingChanges() {
        pendingChanges.removeAll()
    }
}

/// The per-item results dialog for a batch that had at least one failure (ADR-009).
///
/// Shows every row, not only the failures: a user who queued five changes needs to see that
/// the three that worked really did work, not just which two broke. Each row carries an
/// explicit ✅/❌ so the outcome is never ambiguous.
struct BatchReportSheet: View {

    let report: BatchReport
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Some changes were not applied")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Theme.title)

            Text("\(report.failures.count) of \(report.items.count) change(s) failed. "
                 + "The rows marked ❌ are still queued — fix the cause and press ✅ ตกลง again.")
                .font(.system(size: 12))
                .foregroundColor(Theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 0) {
                ForEach(Array(report.items.enumerated()), id: \.offset) { index, item in
                    HStack(spacing: 10) {
                        Text(item.succeeded ? "✅" : "❌")
                            .font(.system(size: 13))
                            .frame(width: 20, alignment: .center)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.feature.title)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(Theme.primaryText)
                            if let message = item.outcome.failureMessage {
                                Text(message)
                                    .font(.system(size: 11))
                                    .foregroundColor(Theme.secondaryText)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 7)
                    .padding(.horizontal, 10)
                    if index < report.items.count - 1 {
                        RowSeparator().padding(.horizontal, 0)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.04))
            )

            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Button("Close") { onDismiss() }
                    .buttonStyle(ConfirmButtonStyle())
                    .frame(width: 120)
            }
        }
        .padding(20)
        .frame(width: 420)
        .background(Theme.backgroundBottom)
    }
}

/// The dark confirmation sheet.
///
/// Destructive requests use a red confirm button so the risk is visible at the moment of
/// the click, not just in the body text.
struct ConfirmationSheet: View {

    let request: ContentView.ConfirmationRequest
    let onResult: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(request.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Theme.title)

            Text(request.message)
                .font(.system(size: 12))
                .foregroundColor(Theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Button("Cancel") { onResult(false) }
                    .buttonStyle(QuickToolButtonStyle())
                    .frame(width: 110)
                Button(request.confirmTitle) { onResult(true) }
                    .buttonStyle(ConfirmButtonStyle(isDestructive: request.isDestructive))
                    .frame(width: 130)
            }
        }
        .padding(20)
        .frame(width: 420)
        .background(Theme.backgroundBottom)
    }
}
