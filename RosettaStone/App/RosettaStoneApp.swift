import SwiftUI
import AppKit

/// The SwiftUI entry point, used on **macOS 11 and newer**.
///
/// On macOS 10.15 `main.swift` boots `AppDelegate` directly instead, because the SwiftUI
/// `App` lifecycle did not exist until Big Sur. Both paths construct the *same*
/// `AppDelegate`, so behaviour is identical across the whole 10.15 → 27 range and there
/// is exactly one implementation to maintain.
///
/// ```swift
/// @available(macOS 11.0, *)
/// struct RosettaStoneApp: App {
///     @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
///     var body: some Scene { Settings { EmptyView() } }   // UI lives in AppKit
/// }
/// ```
///
/// Note there is no `@main` attribute: `main.swift` contains top-level code, and Swift
/// forbids both in one module. `main.swift` calls `RosettaStoneApp.main()` instead.
///
/// - `NSApplicationDelegateAdaptor` hands ownership of `NSApp` to `AppDelegate`, which
///   installs the `NSStatusItem` and the panel. Declaring it here is what wires the two
///   halves together.
/// - `Settings` is used rather than `WindowGroup`: this is an `LSUIElement` agent with a
///   manually managed panel. A `WindowGroup` would create a second, unmanaged window and
///   a menu-bar "Show" item it does not want. `Settings` provides a legal, invisible
///   scene that keeps the SwiftUI lifecycle satisfied.
/// - `onOpenURL` is available from macOS 11, which is why the 10.15 path routes URLs
///   through `application(_:open:)` in the delegate instead.
@available(macOS 11.0, *)
struct RosettaStoneApp: App {

    /// Boots the AppKit side of the app: the status item, the panel window and the
    /// URL-scheme handler.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            // Intentionally empty. The real interface is a SwiftUI view hosted inside an
            // `NSHostingView` in the AppKit-owned `NSWindow` — see `MenuBarController`.
            // This empty scene exists only so the SwiftUI lifecycle has something to run;
            // it never creates a visible window.
            EmptyView()
        }
        .onOpenURL { url in
            // macOS 11+ URL delivery. The delegate's `application(_:open:)` also runs,
            // which is harmless: `URLActionRouter` treats a repeated action as a second
            // explicit request, and the coordinator's busy guard collapses duplicates.
            appDelegate.handle(urls: [url])
        }
    }
}
