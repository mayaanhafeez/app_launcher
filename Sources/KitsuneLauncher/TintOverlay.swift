import AppKit

/// Never key, never main: the panel holds focus the whole time the tint is up, and a
/// tint that took key would resign the panel's — which is the panel's cue to dismiss.
private final class TintWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Swallows the click rather than letting it fall through to the app underneath: a
/// click on a dimmed screen means "close the launcher", not "act on what is under it".
private final class TintView: NSView {
    var onClick: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func rightMouseDown(with event: NSEvent) { onClick?() }
}

/// The wash behind the panel — one borderless window per tinted display, one level
/// under the panel. It holds no state beyond its windows: `PanelController` decides
/// which displays to cover and with which theme, so a display change or a theme reload
/// is just another `show`.
@MainActor
final class TintOverlay {
    struct Target {
        let frame: NSRect
        let theme: Theme
    }

    var onClick: (() -> Void)?
    private var windows: [TintWindow] = []
    /// Bumped by every `show` and `hide`, so a fade-out that finishes after the panel
    /// was reopened does not order the fresh tint out from under it.
    private var generation = 0

    func show(_ targets: [Target], animated: Bool) {
        generation += 1
        guard !targets.isEmpty else { return hide(fade: 0) }
        while windows.count < targets.count { windows.append(makeWindow()) }
        for (window, target) in zip(windows, targets) {
            configure(window, for: target)
            let wasVisible = window.isVisible
            if !wasVisible { window.alphaValue = 0 }
            window.orderFrontRegardless()
            fade(window, to: 1, duration: animated && !wasVisible ? target.theme.tint.fade : 0)
        }
        for window in windows.dropFirst(targets.count) { window.orderOut(nil) }
    }

    func hide(fade duration: TimeInterval) {
        generation += 1
        let claim = generation
        for window in windows where window.isVisible {
            fade(window, to: 0, duration: duration) { [weak self, weak window] in
                guard self?.generation == claim else { return }
                window?.orderOut(nil)
            }
        }
    }

    private func fade(_ window: NSWindow, to alpha: CGFloat, duration: TimeInterval,
                      completion: (@MainActor () -> Void)? = nil) {
        guard duration > 0 else {
            window.alphaValue = alpha
            completion?()
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            window.animator().alphaValue = alpha
        }, completionHandler: completion.map { done in { MainActor.assumeIsolated { done() } } })
    }

    private func makeWindow() -> TintWindow {
        let window = TintWindow(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
        // Directly beneath the panel, so the card is never washed by its own tint. No
        // `isFloatingPanel` here: setting it resets the level to `.floating`.
        window.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        window.hidesOnDeactivate = false
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        // The fade is driven by hand; AppKit's own would run on top of it.
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false

        let content = TintView()
        content.onClick = { [weak self] in self?.onClick?() }
        // A behind-window material blurs whatever the window server has under this
        // window, which is what makes the blur reach other apps without a capture.
        let blur = NSVisualEffectView()
        blur.blendingMode = .behindWindow
        blur.material = .fullScreenUI
        blur.state = .active
        blur.autoresizingMask = [.width, .height]
        content.addSubview(blur)
        // The wash is its own view *above* the blur. Painted on the content view's layer
        // it would sit under its subviews, and a full blur would cover it.
        let wash = NSView()
        wash.wantsLayer = true
        wash.autoresizingMask = [.width, .height]
        content.addSubview(wash)
        window.contentView = content
        return window
    }

    private func configure(_ window: TintWindow, for target: Target) {
        let tint = target.theme.tint
        window.setFrame(target.frame, display: false)
        guard let content = window.contentView, content.subviews.count == 2,
              let blur = content.subviews[0] as? NSVisualEffectView else { return }
        let wash = content.subviews[1]
        blur.frame = content.bounds
        wash.frame = content.bounds
        // The material's radius is fixed, so `blur` is how much of it shows through:
        // the effect view cross-fades between the sharp screen and the blurred one.
        blur.alphaValue = tint.blur
        blur.isHidden = tint.blur <= 0
        wash.layer?.backgroundColor = tint.resolvedColor(in: target.theme).cgColor
    }
}
