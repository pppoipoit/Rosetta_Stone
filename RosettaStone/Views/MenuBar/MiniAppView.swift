import SwiftUI
import AppKit

/// The mini panel: the menu-bar gadget's own interface (Phase 11).
///
/// ## What it is for
///
/// Mode B hides the app entirely — no Dock tile, no window at launch. Before this existed,
/// the status item offered a dropdown of menu items and nothing else: every toggle was
/// either a menu entry that ran immediately, or a trip through "Open Main Window". This panel
/// gives the gadget a real surface — the three switches people actually reach for, staged and
/// committed exactly like the main panel — without ever opening the full window.
///
/// ## It obeys the same deferred queue (ADR-009)
///
/// Nothing here runs on a click. A toggle stages into `pending`, and **OK** commits the lot
/// through `FeatureCoordinator.applyBatch` — one Authorization dialog, exactly as in the main
/// panel. **CANCEL** throws the queue away and snaps back to what the system reports. A panel
/// that executed privileged commands one at a time would reintroduce the password-prompt
/// storm the queue exists to eliminate.
///
/// ## Deliberately only three rows
///
/// Gatekeeper, Hidden Files and Run at Startup. Run at Startup is here because flipping it
/// *is* the mode switch — hiding it would mean the gadget could not get the user back to the
/// full app. Auto Boot and Rosetta are **not**: Auto Boot writes firmware NVRAM and Rosetta
/// takes minutes, and neither belongs in a panel someone opens for a two-second glance. Both
/// stay one "Open Main App" click away.
///
/// ## Reading the staged value
///
/// `MiniToggleRow` is given the **staged** value, not the applied one, and the pending dot
/// rides on the switch via `PendingPillSwitch` — identical to the main panel, because it is
/// literally the same component.
struct MiniAppView: View {

    /// The shared state owner. Observed, never bypassed: the mini panel has no privileged
    /// state of its own and reads actual truth only through `@Published` here.
    @ObservedObject var coordinator: FeatureCoordinator

    /// Closes the panel. Supplied by `MenuBarController`, which owns the `NSPanel`.
    let onDismiss: () -> Void

    /// Brings the full panel forward. Supplied by `MenuBarController`.
    let onOpenMainApp: () -> Void

    /// Arms the menu-bar outcome toast for a committed Gatekeeper change.
    ///
    /// Supplied by `MenuBarController`, which owns `StatusItemToast`. Without it a Gatekeeper
    /// change made here would be reported only inside this 300 pt panel, which the user may
    /// well have dismissed by the time the password prompt is answered. Optional because the
    /// main panel has its own visible footer banner and needs no toast.
    var onArmGatekeeperToast: (() -> Void)? = nil

    /// Staged-but-unapplied changes. Same contract as `ContentView`: keyed by `FeatureID`,
    /// so a row holds at most one intent.
    @State private var pending: [FeatureID: PendingChange] = [:]

    /// Per-item results awaiting display, exactly as in the main panel.
    @State private var batchReport: BatchReport?

    /// The panel's fixed size. Width is generous enough for a two-line description without
    /// truncating; the height is bounded by the three rows plus the OK/CANCEL bar, so the
    /// panel never grows a scroll view it does not need.
    static let panelWidth: CGFloat = 300
    static let panelHeight: CGFloat = 372

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().padding(.horizontal, Theme.contentPadding)
            rows
            Spacer(minLength: 0)
            footer
            commitBar
        }
        .frame(width: MiniAppView.panelWidth, height: MiniAppView.panelHeight)
        .background(Theme.panelBackground)
        .sheet(item: $batchReport) { report in
            BatchReportSheet(report: report) { batchReport = nil }
        }
    }

    // MARK: - Chrome

    /// Title, Gatekeeper status dot, and the close button.
    ///
    /// The status dot is the same `GatekeeperStatusDot` the main panel uses, because
    /// "is this Mac protected?" is the one fact worth surfacing in a panel this small.
    private var header: some View {
        HStack(spacing: 8) {
            Text("Rosetta Stone")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Theme.title)

            GatekeeperStatusDot(state: coordinator.gatekeeperBypassed)

            Spacer(minLength: 0)

            // A real close button rather than relying on a traffic light: the panel carries a
            // `.titled` mask with a hidden title bar, so there is no red dot for the user
            // to find.
            Button(action: onDismiss) {
                Text("✕")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.secondaryText)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
            .accessibilityTitle("Close the mini panel")
        }
        .padding(.horizontal, Theme.contentPadding)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    // MARK: - Rows

    private var rows: some View {
        VStack(spacing: 0) {
            MiniToggleRow(
                feature: .gatekeeper,
                isOn: stagedValue(for: .gatekeeper),
                hasPendingChange: pending[.gatekeeper] != nil,
                isEnabled: coordinator.isBusy == false,
                onStage: { stageToggle(.gatekeeper, newValue: $0) }
            )
            RowSeparator()

            MiniToggleRow(
                feature: .hiddenFiles,
                isOn: stagedValue(for: .hiddenFiles),
                hasPendingChange: pending[.hiddenFiles] != nil,
                isEnabled: coordinator.isBusy == false,
                onStage: { stageToggle(.hiddenFiles, newValue: $0) }
            )
            RowSeparator()

            MiniToggleRow(
                feature: .runAtStartup,
                isOn: stagedValue(for: .runAtStartup),
                hasPendingChange: pending[.runAtStartup] != nil,
                isEnabled: coordinator.isBusy == false,
                onStage: { stageToggle(.runAtStartup, newValue: $0) }
            )
        }
        .padding(.horizontal, Theme.contentPadding)
        .padding(.top, 6)
    }

    // MARK: - Footer

    /// The status line and the route to the full app.
    private var footer: some View {
        VStack(spacing: 8) {
            if let status = coordinator.statusMessage {
                StatusBanner(message: status)
            }

            Button("Open Main App") {
                // Dismiss first: opening the full window while a 300 pt panel is still on
                // screen leaves two panels stacked, and the mini one has no way back.
                onDismiss()
                onOpenMainApp()
            }
            .buttonStyle(Theme.quickToolButton)
            .disabled(coordinator.isBusy)
        }
        .padding(.horizontal, Theme.contentPadding)
        .padding(.bottom, 10)
    }

    /// OK / CANCEL — the same contract as the main panel's `ApplyBar`.
    private var commitBar: some View {
        HStack(spacing: 10) {
            Button("CANCEL") { cancelPendingChanges() }
                .buttonStyle(Theme.secondaryButton)
                .frame(maxWidth: .infinity)
                .disabled(pending.isEmpty || coordinator.isBusy)
                .modifier(ConditionalCommandDeleteShortcut())

            Button("OK") { applyPendingChanges() }
                .buttonStyle(Theme.primaryButton)
                .frame(maxWidth: .infinity)
                .disabled(pending.isEmpty || coordinator.isBusy)
                .modifier(ConditionalCommandReturnShortcut())
        }
        .padding(.horizontal, Theme.contentPadding)
        .padding(.bottom, 14)
        .opacity(pending.isEmpty || coordinator.isBusy ? 0.45 : 1)
    }

    // MARK: - The deferred queue (ADR-009)
    //
    // Deliberately a *copy* of `ContentView`'s four operations rather than a shared
    // abstraction. Two consumers with identical-but-separate five-line logic is cheaper than
    // a generic queue type parameterised over three view concerns (staging rules, hardware
    // gating, confirmations) — and the two can only drift if someone edits one and not the
    // other, which the next person to touch this file sees side by side.

    /// What the system currently reports, in the row's own ON/OFF semantics.
    private func actualValue(for feature: FeatureID) -> Bool {
        switch feature {
        case .runAtStartup: return coordinator.runAtStartup
        case .gatekeeper:   return coordinator.gatekeeperBypassed ?? false
        case .hiddenFiles:  return coordinator.hiddenFilesShown
        default:            return false
        }
    }

    /// The staged value if one exists, else reality — so the switch always shows the user's
    /// intent rather than what the system has already agreed to.
    private func stagedValue(for feature: FeatureID) -> Bool {
        if case .toggle(let value)? = pending[feature] { return value }
        return actualValue(for: feature)
    }

    /// Records a desired toggle value, dropping an entry that matches reality — a change
    /// equal to the actual state is not pending by definition.
    private func stageToggle(_ feature: FeatureID, newValue: Bool) {
        guard newValue != actualValue(for: feature) else {
            pending.removeValue(forKey: feature)
            return
        }
        pending[feature] = .toggle(newValue)
    }

    /// Commits the queue: one Authorization dialog for the lot, then every dot clears
    /// unconditionally (Phase 11) and reality is re-read.
    private func applyPendingChanges() {
        guard pending.isEmpty == false, coordinator.isBusy == false else { return }

        let commands = FeatureID.allCases.compactMap { feature -> FeatureCommand? in
            guard let staged = pending[feature] else { return nil }
            return coordinator.command(for: feature, pending: staged)
        }

        guard commands.isEmpty == false else {
            // Everything staged turned out to be a no-op. Drop the queue rather than
            // leaving undotable rows behind.
            pending.removeAll()
            return
        }

        // Armed *before* the batch runs, because a fast failure can publish its message
        // before this function returns.
        if pending[.gatekeeper] != nil {
            onArmGatekeeperToast?()
        }

        coordinator.applyBatch(commands) { report in
            // A dismissed password dialog is "not now", not a result: keep the queue so OK
            // can be pressed again without re-staging anything.
            guard report.wasCancelled == false else { return }
            pending.removeAll()
            if report.allSucceeded == false {
                batchReport = report
            }
        }
    }

    /// Discards the queue and re-reads reality. A state read is unprivileged, so this is
    /// free and can always be done.
    private func cancelPendingChanges() {
        pending.removeAll()
        coordinator.loadState()
    }
}

/// One compact row in the mini panel: name, description, pending switch.
///
/// The whole row is one hit target, matching the main panel — a 300 pt panel is too small to
/// afford a separate switch hit area, and a row that is easy to miss is worse than one that
/// is easy to hit.
struct MiniToggleRow: View {

    let feature: FeatureID

    /// The staged value, else reality.
    let isOn: Bool

    let hasPendingChange: Bool

    /// `false` while any operation is in flight, so a staged change can never collide with a
    /// live batch.
    let isEnabled: Bool

    let onStage: (Bool) -> Void

    var body: some View {
        Button {
            onStage(!isOn)
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(feature.displayName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Theme.primaryText)
                    Text(feature.description)
                        .font(.system(size: 10))
                        .foregroundColor(Theme.secondaryText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 6)

                PendingPillSwitch(isOn: isOn, hasPendingChange: hasPendingChange)
            }
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(isEnabled == false)
        .opacity(isEnabled ? 1 : 0.45)
    }
}