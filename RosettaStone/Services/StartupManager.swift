import Foundation
import Darwin

/// Feature 1 — "Run at Startup".
///
/// Installs or removes the per-user LaunchAgent
/// `~/Library/LaunchAgents/com.rosettastone.helper.plist` so the menu-bar icon
/// reappears at every login.
///
/// A **LaunchAgent**, not a LaunchDaemon: it must run inside the user's Aqua session
/// to be able to show a status item at all (`docs/ARCHITECTURE.md` §2).
struct StartupManager {

    static let label = "com.rosettastone.helper"
    static let fileName = "com.rosettastone.helper.plist"

    /// `~/Library/LaunchAgents/com.rosettastone.helper.plist`
    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(fileName)")
    }

    // MARK: - Unprivileged state read

    /// ON == the plist exists. This read never prompts for a password.
    ///
    /// A *stale* plist (left over from an install at a different path) still counts as
    /// ON, per `docs/FEATURES.md` §1 — `launchctl list` is deliberately not consulted.
    func isInstalled() -> Bool {
        FileManager.default.fileExists(atPath: StartupManager.plistURL.path)
    }

    /// The executable path recorded in the installed plist, if readable and parseable.
    func installedExecutablePath() -> String? {
        guard let data = try? Data(contentsOf: StartupManager.plistURL) else { return nil }
        guard let plist = try? PropertyListSerialization.propertyList(from: data,
                                                                   options: [],
                                                                   format: nil) as? [String: Any],
              let arguments = plist["ProgramArguments"] as? [String],
              let first = arguments.first else { return nil }
        return first
    }

    /// True when the plist points at a path that no longer exists — the user moved the app.
    /// Surfaced as a warning until the toggle is cycled off → on.
    func hasStaleExecutablePath() -> Bool {
        guard let recorded = installedExecutablePath() else { return false }
        return !FileManager.default.fileExists(atPath: recorded)
    }

    /// Absolute path of the running executable, e.g.
    /// `/Applications/RosettaStone.app/Contents/MacOS/RosettaStone`.
    ///
    /// `executableURL` is optional in principle, but it is never nil for a running
    /// `.app` — `Info.plist` declares `CFBundleExecutable` and the binary is present.
    /// The fallback keeps the LaunchAgent writable rather than trapping, because a
    /// trap here would happen *while enabling Run at Startup*, i.e. exactly when the
    /// user is least able to recover.
    static var currentExecutablePath: String {
        let name = Bundle.main.executableURL?.lastPathComponent
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleExecutable") as? String
            ?? "RosettaStone"
        return Bundle.main.bundlePath + "/Contents/MacOS/" + name
    }

    /// The real UID of this process, used for the `gui/<uid>` launchctl domain and for
    /// `chown`ing the installed plist back to the user.
    ///
    /// `getuid()` rather than `ProcessInfo.userIdentifier`: the latter does not exist.
    /// The process is never elevated at this point — elevation happens only inside the
    /// child `osascript` shell — so `getuid()` is the user's UID, which is what the
    /// LaunchAgent has to be owned by.
    static var userID: uid_t { getuid() }

    // MARK: - Install / remove (elevated)

    /// Writes the plist and loads it. Requires administrator privileges.
    ///
    /// The plist is staged in a temporary file first and copied into place by a root
    /// shell, so the elevated command interpolates only quoted, app-controlled values.
    func install() -> CommandOutcome {
        let plistXML: Data
        do {
            plistXML = try makePlist(executablePath: StartupManager.currentExecutablePath)
        } catch {
            return .failure(message: "Could not build the LaunchAgent file: \(error.localizedDescription)",
                            exitCode: -1)
        }

        let stagingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("com.rosettastone.helper.\(UUID().uuidString).plist")
        do {
            try plistXML.write(to: stagingURL, options: .atomic)
        } catch {
            return .failure(message: "Could not stage the LaunchAgent file: \(error.localizedDescription)",
                            exitCode: -1)
        }

        let uid = StartupManager.userID
        let destination = SystemCommands.shellQuoted(StartupManager.plistURL.path)
        let staged = SystemCommands.shellQuoted(stagingURL.path)
        let directory = SystemCommands.shellQuoted(StartupManager.plistURL.deletingLastPathComponent().path)
        // `launchctl bootstrap` is the modern spelling; `load` is the 10.15-era one.
        // Both are allowed to fail — `RunAtLoad` makes the job effective at next login.
        let script = """
        /bin/mkdir -p \(directory) && \
        /bin/cp \(staged) \(destination) && \
        /bin/chown \(uid) \(destination) && \
        /bin/launchctl bootstrap "gui/\(uid)" \(destination) 2>/dev/null || \
        /bin/launchctl load \(destination) 2>/dev/null || true
        """

        defer { try? FileManager.default.removeItem(at: stagingURL) }
        return SystemCommands.runAsAdmin(script)
    }

    /// Unloads and deletes the plist. Requires administrator privileges.
    ///
    /// `launchctl unload` fails when the job was never loaded; that is deliberately
    /// swallowed because a successful deletion is what the user asked for.
    func remove() -> CommandOutcome {
        let uid = StartupManager.userID
        let path = SystemCommands.shellQuoted(StartupManager.plistURL.path)
        let script = """
        (/bin/launchctl bootout "gui/\(uid)" \(path) 2>/dev/null || /bin/launchctl unload \(path) 2>/dev/null || true) && \
        /bin/rm -f \(path)
        """
        return SystemCommands.runAsAdmin(script)
    }

    // MARK: - Plist construction

    /// Builds the LaunchAgent plist.
    ///
    /// `ProgramArguments` is an absolute path — a LaunchAgent inherits no usable `PATH`
    /// and cannot resolve a bare executable name.
    private func makePlist(executablePath: String) throws -> Data {
        let plist: [String: Any] = [
            "Label": StartupManager.label,
            "ProgramArguments": [executablePath],
            "RunAtLoad": true,
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua"
        ]
        return try PropertyListSerialization.data(fromPropertyList: plist,
                                                  format: .xml,
                                                  options: 0)
    }
}
