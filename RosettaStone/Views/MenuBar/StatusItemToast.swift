import AppKit

/// A transient HUD: the feedback channel for the menu-bar gadget's direct actions.
///
/// The left-click Gatekeeper toggle is deliberately silent — no dropdown, no panel, no
/// window — so this is the only place its outcome can be seen. It is a borderless,
/// non-activating panel: it never becomes key, never steals focus, never joins ⌘-Tab, and
/// fades itself out.
///
/// An in-app HUD rather than `UNUserNotificationCenter`, for three reasons: it needs no
/// permission prompt, it cannot be silently swallowed by Focus or notification settings,
/// and it works in a background-only process that owns no window at all.
enum StatusItemToast {

    /// Retained while visible. A panel with no strong reference is deallocated the instant
    /// `show(_:near:)` returns, which would make it blink and vanish.
    private static var active: NSPanel?

    /// Seconds the toast stays fully visible before it fades out.
    private static let visibleDuration: TimeInterval = 2.4

    /// Shows `text` just under the status item, replacing any toast already on screen.
    ///
    /// Main-thread only, asserted rather than annotated: the project targets Swift 5.0 /
    /// macOS 10.15, where `@MainActor` is not available.
    static func show(_ text: String, near button: NSStatusBarButton?) {
        assert(Thread.isMainThread, "the toast must be presented on the main thread")
        guard text.isEmpty == false else { return }

        // Replace rather than stack: two overlapping HUDs help nobody.
        if let previous = active {
            previous.orderOut(nil)
        }

        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let maxWidth: CGFloat = 340
        let measured = (text as NSString).boundingRect(
            with: NSSize(width: maxWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font])
        let size = NSSize(width: min(maxWidth, ceil(measured.width)) + 28,
                          height: ceil(measured.height) + 18)

        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // Above ordinary windows so it is never buried, and never focusable.
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        panel.animationBehavior = .utilityWindow

        let material = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        // Always dark, like the panel itself — the HUD must read the same in light and dark.
        material.appearance = NSAppearance(named: .vibrantDark)
        material.material = .hudWindow
        material.blendingMode = .behindWindow
        material.state = .active
        material.wantsLayer = true
        material.layer?.cornerRadius = 9
        material.layer?.masksToBounds = true

        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = .white
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.frame = NSRect(x: 14, y: 9, width: size.width - 28, height: size.height - 18)
        label.autoresizingMask = [.width, .height]
        material.addSubview(label)

        panel.contentView = material
        panel.setFrameOrigin(origin(for: panel.frame.size, near: button))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        active = panel
        Trace.log("toast shown \"\(text)\"")

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            panel.animator().alphaValue = 1
        }

        // `DispatchQueue.main.asyncAfter` rather than a `Timer`: a timer would keep the
        // runloop alive — and the toast on screen — if the user quits straight afterwards.
        DispatchQueue.main.asyncAfter(deadline: .now() + visibleDuration) { [weak panel] in
            guard let panel = panel else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.25
                panel.animator().alphaValue = 0
            }, completionHandler: {
                panel.orderOut(nil)
                if active === panel { active = nil }
            })
        }
    }

    /// Fades the current toast out immediately.
    ///
    /// Used when the direct toggle ends without producing a message of its own — the user
    /// dismissed the password prompt — so the “waiting for authorization” toast does not
    /// linger and imply something is still in flight.
    static func dismiss() {
        guard let panel = active else { return }
        active = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }

    /// Just under the status item when its button is on screen, otherwise the top-right
    /// corner of the main display.
    private static func origin(for size: NSSize, near button: NSStatusBarButton?) -> NSPoint {
        if let hostWindow = button?.window {
            let host = hostWindow.frame
            return NSPoint(x: host.midX - size.width / 2,
                           y: host.minY - size.height - 6)
        }
        if let visible = NSScreen.main?.visibleFrame {
            return NSPoint(x: visible.maxX - size.width - 16,
                           y: visible.maxY - size.height - 16)
        }
        return NSPoint(x: 16, y: 16)
    }
}