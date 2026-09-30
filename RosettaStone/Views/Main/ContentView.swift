import SwiftUI
import AppKit

/// The dark-mode feature panel — the app's only window.
///
/// ## Row order (fixed, from `docs/FEATURES.md` "Row order")
/// 1. Run at Startup · 2. Gatekeeper · 3. Hidden Files · 4. Auto Boot ·
/// 5. Rosetta 2 · 6. Quick Tools (Spotlight / DNS / Cache)
///
/// ## CPU gating
/// Two rows are gated on the architecture detected by `uname -m`:
/// - **Auto Boot** is disabled with a 🔒 on `arm64` — the `AutoBoot` NVRAM variable
///   does not exist on Apple Silicon.
/// - **Rosetta 2** is disabled with a 🔒 on `x86_64` — Rosetta is an Apple Silicon feature.
///
/// Both are **greyed out, never hidden**, so the panel looks the same on every machine and
/// the padlock explains the absence instead of making the feature look missing.
///
/// The view observes `FeatureCoordinator` and never spawns a process itself — layering
/// rule 1 of `docs/ARCHITECTURE.md` §6.
struct ContentView: View {

    /// Window size, also used by `MenuBarController` when creating the `NSWindow`.
    static let panelWidth: CGFloat = 460
    static let panelHeight: CGFloat = 540

    @ObservedObject var coordinator: FeatureCoordinator

    /// A pending confirmation, presented as a sheet.
    @State private var pendingConfirmation: ConfirmationRequest?

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
        }
        .padding(.top, 26)
        .padding(.bottom, 16)
        .padding(.horizontal, Theme.contentPadding)
    }

    /// Centred title plus the detected architecture, so the locked rows have context.
    private var header: some View {
        VStack(spacing: 4) {
            Text("Rosetta Stone")
                .font(.system(size: 21, weight: .bold))
                .foregroundColor(Theme.title)
            Text("macOS \(ContentView.osVersionText) · \(coordinator.architecture.displayName)")
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
            Text("Version \(MenuBarController.versionString)")
                .font(.system(size: 10))
                .foregroundColor(Theme.secondaryText.opacity(0.7))
        }
        .padding(.top, 12)
    }

    // MARK: - Rows

    /// The five feature rows, in the fixed order, plus the Quick Tools grid.
    private var rows: some View {
        VStack(spacing: 0) {
            // 1. Run at Startup — admin
            toggleRow(
                feature: .runAtStartup,
                isOn: Binding(get: { coordinator.runAtStartup },
                              set: { coordinator.setRunAtStartup($0) })
            )
            RowSeparator()

            // 2. Gatekeeper — admin, INVERTED: ON == bypassed (less secure)
            toggleRow(
                feature: .gatekeeper,
                isOn: Binding(get: { coordinator.gatekeeperBypassed ?? false },
                              set: { coordinator.setGatekeeper(bypassed: $0) })
            )
            RowSeparator()

            // 3. Hidden Files — no elevation, INVERTED: ON == hidden files shown
            toggleRow(
                feature: .hiddenFiles,
                isOn: Binding(get: { coordinator.hiddenFilesShown },
                              set: { coordinator.setHiddenFiles(shown: $0) })
            )
            RowSeparator()

            // 4. Auto Boot — admin, Intel only. Disabled + lock on arm64.
            toggleRow(
                feature: .autoBoot,
                isOn: Binding(get: { coordinator.autoBootEnabled ?? false },
                              set: { confirmAutoBoot(enabled: $0) })
            )
            RowSeparator()

            // 5. Rosetta 2 — admin, Apple Silicon only. Disabled + lock on x86_64.
            rosettaRow
            RowSeparator()

            // 6. Quick Tools
            quickTools
        }
    }

    /// A toggle row: title, one-line detail, and the pill switch.
    ///
    /// The row is a `Button` rather than a `Toggle` so the whole row is one hit target
    /// and the app controls its own switch rendering (see `PillSwitch`). `.disabled(...)`
    /// covers three cases at once: the row is CPU-locked, its own command is in flight, or
    /// *any* command is in flight. When locked the label is greyed via `opacity` and the
    /// reason replaces the usual description in the subtitle.
    private func toggleRow(feature: FeatureID, isOn: Binding<Bool>) -> some View {
        let availability = coordinator.availability(for: feature)
        let isBusy = coordinator.busyFeature == feature
        let isInteractive = availability.isEnabled && coordinator.isBusy == false

        return Button {
            // `isOn` is an immutable parameter, so the binding's own `set` closure is
            // used rather than calling the mutating `wrappedValue.toggle()` on it —
            // that would try to mutate a `let` and would also bypass the coordinator.
            // Each row's `set` is a pure request (e.g. `setGatekeeper(bypassed:)`), and
            // the coordinator re-reads real state afterwards, so deriving the new value
            // from the *current* one here is what keeps the pill honest.
            isOn.wrappedValue = !isOn.wrappedValue
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(feature.title)
                        .font(.system(size: 15, weight: .regular))
                        .foregroundColor(availability.isEnabled ? Theme.primaryText : Theme.secondaryText)
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
                    PillSwitch(isOn: isOn.wrappedValue)
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

        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(FeatureID.rosetta2.title)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundColor(availability.isEnabled ? Theme.primaryText : Theme.secondaryText)
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
                Button("Install") { confirmRosettaInstall() }
                    .buttonStyle(AccentButtonStyle())
                    .disabled(coordinator.isBusy || availability.isEnabled == false)
            }
        }
        .opacity(availability.isEnabled ? 1 : 0.45)
        .frame(minHeight: Theme.rowSpacing * 1.9)
    }

    /// Features 6, 7 and 8 — the one-shot maintenance buttons.
    ///
    /// Each disables itself while *any* operation is in flight, so only one Authorization
    /// dialog can ever be on screen.
    private var quickTools: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Quick Tools")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Theme.primaryText)
                .padding(.top, 16)

            HStack(spacing: 10) {
                quickToolButton(title: "Spotlight",
                                busy: coordinator.busyFeature == .spotlightRebuild,
                                action: confirmSpotlightRebuild)
                quickToolButton(title: "DNS",
                                busy: coordinator.busyFeature == .dnsFlush,
                                action: confirmDNSFlush)
                quickToolButton(title: "Cache",
                                busy: coordinator.busyFeature == .clearSystemCache,
                                action: confirmClearCache)
            }
        }
    }

    private func quickToolButton(title: String,
                                busy: Bool,
                                action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if busy { BusySpinner(size: 12) }
                Text(title)
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
            coordinator.setAutoBoot(enabled: enabled)
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
            coordinator.installRosetta()
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
            coordinator.rebuildSpotlight()
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
            coordinator.flushDNS()
        }
    }

    /// Feature 8 — the highest-risk action in the app. Confirmation **and** auth prompt.
    private func confirmClearCache() {
        pendingConfirmation = ConfirmationRequest(
            title: "Clear the system cache?",
            message: "Everything inside /Library/Caches will be deleted. Open applications may "
                + "misbehave and need to be restarted, and there is no way to undo this.",
            confirmTitle: "Clear Cache",
            isDestructive: true
        ) {
            coordinator.clearSystemCache()
        }
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
