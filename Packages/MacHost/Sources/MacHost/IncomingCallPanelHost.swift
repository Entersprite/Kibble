import AppKit
import DesignSystem
import SwiftUI

/// The incoming call panel's window: top right, over every app and Space,
/// clickable without activating Kibble.
///
/// A `.nonactivatingPanel` takes clicks while another app stays active; it is
/// ordered front without becoming key, so typing elsewhere is not interrupted.
/// `.statusBar` keeps it above other apps' floating windows and below menus.
@MainActor
final class IncomingCallPanelHost {
    struct Actions {
        let accept: () -> Void
        let decline: () -> Void
        let open: () -> Void
        let dismiss: () -> Void
        var imageLoader: SceneImageLoader?
    }

    private let reduceMotion: () -> Bool
    private let animates: Bool
    private(set) var panel: NSPanel?
    private var content: IncomingCallPanelContent?
    private var actions: Actions?
    private var hosting: IncomingCallPanelHostingView?
    private var hideGeneration = 0

    init(
        reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
        animates: Bool = true
    ) {
        self.reduceMotion = reduceMotion
        self.animates = animates
    }

    var isVisible: Bool {
        panel?.isVisible == true && content != nil
    }

    /// Shows the panel for a call, or updates it in place for the same call.
    func show(_ content: IncomingCallPanelContent, actions: Actions) {
        let isNew = self.content?.callID != content.callID || panel?.isVisible != true
        self.content = content
        self.actions = actions
        hideGeneration += 1
        let panel = panel ?? makePanel()
        self.panel = panel
        render()
        guard isNew else { return }
        let target = Self.frame(on: NSScreen.main ?? NSScreen.screens.first)
        let slides = animates && !reduceMotion()
        panel.setFrame(slides ? target.offsetBy(dx: 30, dy: 0) : target, display: false)
        panel.alphaValue = animates ? 0 : 1
        panel.orderFrontRegardless()
        if animates {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(target, display: true)
                panel.animator().alphaValue = 1
            }
        }
        NSAccessibility.post(
            element: panel, notification: .announcementRequested,
            userInfo: [
                .announcement: content.name.map { "Incoming call from \($0)" } ?? "Incoming call",
                .priority: NSAccessibilityPriorityLevel.high.rawValue
            ]
        )
    }

    func hide() {
        content = nil
        actions = nil
        guard let panel, panel.isVisible else { return }
        guard animates else {
            panel.orderOut(nil)
            return
        }
        hideGeneration += 1
        let generation = hideGeneration
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self, weak panel] in
            MainActor.assumeIsolated {
                // A new call shown during the fade keeps its panel.
                guard let self, self.hideGeneration == generation else { return }
                panel?.orderOut(nil)
            }
        }
    }

    /// Top right of the screen in use, where notification banners appear.
    static func frame(on screen: NSScreen?) -> NSRect {
        let size = IncomingCallPanelLayout.window
        guard let visible = screen?.visibleFrame else { return NSRect(origin: .zero, size: size) }
        // The window's margin already spaces the glass from the edges.
        let inset = 12 - IncomingCallPanelLayout.margin
        return NSRect(
            x: visible.maxX - size.width - inset, y: visible.maxY - size.height - inset,
            width: size.width, height: size.height
        )
    }

    private func render() {
        guard let content, let actions else { return }
        let view = IncomingCallPanelView(
            content: content, isHovering: hosting?.isHovering ?? false,
            accept: actions.accept, decline: actions.decline, open: actions.open, dismiss: actions.dismiss,
            imageLoader: actions.imageLoader
        )
        if let hosting {
            hosting.rootView = view
        } else {
            let hosting = IncomingCallPanelHostingView(rootView: view)
            hosting.hoverChanged = { [weak self] in self?.render() }
            panel?.contentView = hosting
            self.hosting = hosting
        }
    }

    private func makePanel() -> NSPanel {
        let panel = IncomingCallPanel(
            contentRect: NSRect(origin: .zero, size: IncomingCallPanelLayout.window),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.identifier = CallSurface.incomingPanel
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovable = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        return panel
    }
}

/// Never key or main: the person keeps typing where they were.
private final class IncomingCallPanel: NSPanel {
    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }
}

/// Takes the first click without needing the window to be active, and tracks
/// hover itself: SwiftUI's hover follows the key window, which this never is.
private final class IncomingCallPanelHostingView: NSHostingView<IncomingCallPanelView> {
    var hoverChanged: (() -> Void)?
    private(set) var isHovering = false

    required init(rootView: IncomingCallPanelView) {
        super.init(rootView: rootView)
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil
        ))
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    override func mouseEntered(with _: NSEvent) {
        isHovering = true
        hoverChanged?()
    }

    override func mouseExited(with _: NSEvent) {
        isHovering = false
        hoverChanged?()
    }
}
