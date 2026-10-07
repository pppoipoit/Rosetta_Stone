import Foundation
import Darwin

/// Feature 1 — "Run at Startup".
///
/// Installs or removes the per-user LaunchAgent
/// `~/Library/LaunchAgents/com.rosettastone.helper.plist` so the menu-bar icon
/// reappears at every login.
///
/// This is also the **mode switch of the whole app**: ON makes Rosetta Stone a menu-bar
/// gadget (hidden launch, no Dock icon), OFF returns it to an ordinary
/// windowed app. `AppMode` and `AppDelegate.apply(_:)` carry the runtime half of that
/// switch; this type owns only the file on disk, which is the source of truth the toggle
/// is derived from.
///
/// ## No elevation (P1 #4)
///
/// The file lives in the user's **own home directory**, so every write is a plain
/// `FileManager` call. Turning Run at Startup on or off must never raise a macOS password
/// dialog — it changes the user's own preferences, not the system's. See `install()`.
///
/// A **LaunchAgent**, not a LaunchDaemon: it must run inside the user's Aqua session
/// to be able to show a status item at all (`docs/ARCHITECTURE.md` §2).
struct StartupManager {

    static let label = "com.rosettastone.helper"
    static let fileName = "com.rosettastone.helper.plist"

    /// The argument appended to the LaunchAgent's `ProgramArguments`.
    ///
    /// Read back by `AppDelegate.requestedMenuBarOnly()`. Both sides reference this one
    /// constant, so the flag cannot drift between the writer and the reader.
    static let menuBarOnlyArgument = "--menu-bar-only"

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

    /// True when the installed plist passes `--menu-bar-only`.
    ///
    /// The flag is belt-and-braces: mode B is derived from the plist's *existence*, so
    /// even a plist written before the flag existed still launches as the hidden gadget.
    /// Surfaced by Diagnostics because it distinguishes a login item written by the
    /// current build from an older one.
    func installedPlistIsMenuBarOnly() -> Bool {
        guard let data = try? Data(contentsOf: StartupManager.plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data,
                                                                     options: [],
                                                                     format: nil) as? [String: Any],
              let arguments = plist["ProgramArguments"] as? [String] else { return false }
        return arguments.contains(StartupManager.menuBarOnlyArgument)
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

    /// The real UID of this process.
    ///
    /// `getuid()` rather than `ProcessInfo.userIdentifier`: the latter does not exist.
    /// The process is never elevated at this point, so `getuid()` is the user's UID. It is
    /// retained only for the Diagnostics-adjacent comment about `gui/<uid>`; the write path
    /// no longer shells out and no longer needs to `chown` anything, because the file is
    /// created by the user who owns the directory it goes into.
    static var userID: uid_t { getuid() }

    // MARK: - Install / remove (unprivileged — this is the user's own home directory)

    /// Writes the plist with `FileManager`. **No administrator privileges.**
    ///
    /// ## Why there is no `osascript` elevation here (P1 #4)
    ///
    /// The target is `~/Library/LaunchAgents/` — the user's **own home directory**, already
    /// writable by the running user. The Phase-6 implementation ran a root shell
    /// (`osascript … with administrator privileges`) to `mkdir`/`cp`/`chown` a file into it,
    /// which meant that flipping "Run at Startup" — the most-used toggle in the app, and
    /// the one that switches the app's whole posture — raised a macOS password dialog to
    /// perform a `FileManager.createDirectory` + `Data.write`. On a machine where the user
    /// is not in the admin group the toggle was simply broken, and where they were it
    /// looked like the app demanded credentials for its own preferences.
    ///
    /// Two further reasons this is not merely inconvenient but actively wrong:
    /// - A root-owned plist in the user's LaunchAgents directory is a **stale-ownership
    ///   bug source**: the next install could not replace it without another prompt.
    /// - `SystemCommands.runAsAdmin` shows the password sheet, which **steals focus**.
    ///   Switching posture must not yank the user out of whatever they were doing.
    ///
    /// ## Why no `launchctl` step
    ///
    /// **`launchctl bootstrap`/`load` would launch a second instance immediately.** The
    /// job is `RunAtLoad`, so loading it starts the app *right now*, alongside the
    /// instance performing the install — two processes, two status items. The running
    /// process becomes the gadget itself (`AppDelegate.apply(_:)`), and the job file only
    /// has to exist for launchd to load it at the next login, which is exactly what launchd
    /// does for every plist in `~/Library/LaunchAgents` without any explicit load.
    func install() -> CommandOutcome {
        let plistXML: Data
        do {
            plistXML = try makePlist(executablePath: StartupManager.currentExecutablePath)
        } catch {
            return .failure(message: "Could not build the LaunchAgent file: \(error.localizedDescription)",
                            exitCode: -1)
        }

        let fileManager = FileManager.default
        let directory = StartupManager.plistURL.deletingLastPathComponent()
        do {
            // `~/Library/LaunchAgents` exists on any Mac that has ever shown a login item,
            // but not necessarily in a bare account, so it is created if missing.
            try fileManager.createDirectory(at: directory,
                                            withIntermediateDirectories: true,
                                            attributes: nil)
            // `.atomic` writes to a temporary file and renames, so a crash mid-write can
            // never leave launchd a truncated plist that fails to load at the next login.
            try plistXML.write(to: StartupManager.plistURL, options: .atomic)
        } catch {
            Trace.log("install failed: \(error.localizedDescription)")
            return .failure(
                message: "Could not write the login item to \(directory.path): \(error.localizedDescription)",
                exitCode: -1)
        }

        Trace.log("login item written without elevation: \(StartupManager.plistURL.path)")
        return .success(output: StartupManager.plistURL.path)
    }

    /// Deletes the plist with `FileManager`. **No administrator privileges.**
    ///
    /// ## Why no `launchctl bootout` here
    ///
    /// When the toggle is turned OFF, this process was very likely started **by** that
    /// LaunchAgent — it is the at-login instance. `launchctl bootout` terminates a
    /// running job, so it would kill the app mid-operation instead of letting it remove
    /// its menu-bar icon and return to normal mode, which is exactly what the toggle
    /// promises. `bootout` in the per-user `gui/<uid>` domain does not need root — the
    /// earlier `sudo` claim was equally wrong there — but it is still the wrong command:
    /// deleting the plist is sufficient, because launchd only loads what exists at the
    /// next login and the already-loaded job will not restart the app (no `KeepAlive`).
    func remove() -> CommandOutcome {
        let fileManager = FileManager.default
        do {
            try fileManager.removeItem(at: StartupManager.plistURL)
        } catch CocoaError.fileNoSuchFile {
            // Already gone. Report success: the toggle's promise ("no login item") holds.
            Trace.log("login item already absent — nothing to remove")
            return .success(output: "already absent")
        } catch {
            Trace.log("remove failed: \(error.localizedDescription)")
            return .failure(
                message: "Could not delete the login item: \(error.localizedDescription)",
                exitCode: -1)
        }

        Trace.log("login item deleted without elevation: \(StartupManager.plistURL.path)")
        return .success(output: StartupManager.plistURL.path)
    }

    // MARK: - Plist construction

    /// Builds the LaunchAgent plist.
    ///
    /// ## Why `--menu-bar-only` is passed
    ///
    /// The plist execs the **binary directly** — never `open -a`, which would be an
    /// indirect launch that can be swallowed by Launch Services and that loses the
    /// process's own arguments.
    /// `AppMode.resolve(menuBarOnlyArgument:launchAgentInstalled:)` reads this flag and
    /// the app then launches as the hidden menu-bar gadget — the launch posture of
    /// mode B.
    ///
    /// ## Why this flag is the app's only route into gadget mode
    ///
    /// It is what makes a manual double-click unambiguously "the user wants a window",
    /// even with this plist sitting in `~/Library/LaunchAgents` (Phase-6 audit, P0). The
    /// plist's *existence* decides the next login's posture; only this *argument* decides
    /// a given process's posture.
    ///
    /// That is the hard requirement for "Run at Startup": with the toggle ON the login
    /// launch must be a menu-bar gadget — hidden at login, no Dock icon, and no panel
    /// shoving itself in the user's face at every login.
    ///
    /// `ProgramArguments[0]` is an absolute path — a LaunchAgent inherits no usable `PATH`
    /// and cannot resolve a bare executable name.
    private func makePlist(executablePath: String) throws -> Data {
        let plist: [String: Any] = [
            "Label": StartupManager.label,
            "ProgramArguments": [executablePath, StartupManager.menuBarOnlyArgument],
            "RunAtLoad": true,
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua"
        ]
        return try PropertyListSerialization.data(fromPropertyList: plist,
                                                  format: .xml,
                                                  options: 0)
    }
}
