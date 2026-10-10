#if os(macOS)
    import AppKit
    import SwiftUI

    /// What SwiftUI's three-column `NavigationSplitView` does not do for the
    /// thread column, done in AppKit (session 64):
    ///
    /// 1. **A titlebar section of its own.** An `NSTrackingSeparatorToolbarItem`
    ///    on the split view's second divider, as Mail has on the divider before
    ///    its viewer. SwiftUI makes none there (and none for the sidebar once
    ///    its toggle is removed), so the conversation and the thread shared a
    ///    section, and so one backdrop group for their scroll-edge blurs, and
    ///    the thread's drew a flat gray.
    ///    The item goes in through SwiftUI's own toolbar delegate, wrapped
    ///    (`ToolbarSeparatorDelegate`), and a flexible space after it keeps
    ///    Follow and Close at the section's trailing edge.
    /// 2. **No thread, no column.** The split view item is collapsed while no
    ///    thread is open, which SwiftUI cannot do for a detail column, and it
    ///    reopens at its last width (`ThreadColumnLayout`).
    ///
    /// Re-applied on every update and after it, and whenever the toolbar loses
    /// the separator: SwiftUI resets its toolbar's items when its toolbar
    /// content changes, and dropped the separator once at launch (session 64,
    /// traced), and it may hand the toolbar a new delegate.
    struct ThreadColumnBridge: NSViewRepresentable {
        let isOpen: Bool

        func makeCoordinator() -> Coordinator {
            Coordinator()
        }

        func makeNSView(context: Context) -> BridgeView {
            let view = BridgeView()
            view.coordinator = context.coordinator
            return view
        }

        func updateNSView(_ view: BridgeView, context: Context) {
            context.coordinator.isOpen = isOpen
            view.coordinator = context.coordinator
            context.coordinator.apply(in: view.window)
            DispatchQueue.main.async { [weak view] in
                view?.coordinator?.apply(in: view?.window)
            }
        }

        /// Draws nothing and takes no clicks; it is here to know the window.
        final class BridgeView: NSView {
            weak var coordinator: Coordinator?

            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                coordinator?.apply(in: window)
                DispatchQueue.main.async { [weak self] in
                    self?.coordinator?.apply(in: self?.window)
                }
            }

            override func hitTest(_: NSPoint) -> NSView? {
                nil
            }
        }

        @MainActor
        final class Coordinator {
            var isOpen = false
            private var delegate: ToolbarSeparatorDelegate?
            /// The thread column's width when it last closed, only once this
            /// bridge has opened it: SwiftUI lays the detail column out before
            /// any thread exists, at a width nobody chose (session 64, measured:
            /// 1,027 of 1,432 pt).
            private var rememberedWidth: CGFloat?
            private var hasOpened = false

            func apply(in window: NSWindow?) {
                guard let window, let frame = window.contentView?.superview,
                      let controller = Self.splitController(in: frame)
                else { return }
                installSeparator(in: window, splitView: controller.splitView)
                setOpen(isOpen, in: controller)
            }

            /// SwiftUI's split view controller with its three items.
            private static func splitController(in view: NSView) -> NSSplitViewController? {
                if let split = view as? NSSplitView,
                   let controller = split.delegate as? NSSplitViewController,
                   controller.splitViewItems.count == 3 {
                    return controller
                }
                for child in view.subviews {
                    if let found = splitController(in: child) {
                        return found
                    }
                }
                return nil
            }

            private weak var window: NSWindow?
            private weak var observedToolbar: NSToolbar?
            private var removal: NSObjectProtocol?

            /// SwiftUI resets its toolbar's items when its toolbar content
            /// changes, which drops ours; put them back on the next turn.
            private func observe(_ toolbar: NSToolbar) {
                guard observedToolbar !== toolbar else { return }
                if let removal {
                    NotificationCenter.default.removeObserver(removal)
                }
                observedToolbar = toolbar
                removal = NotificationCenter.default.addObserver(
                    forName: NSToolbar.didRemoveItemNotification, object: toolbar, queue: .main
                ) { [weak self] note in
                    let item = note.userInfo?["item"] as? NSToolbarItem
                    MainActor.assumeIsolated {
                        guard item?.itemIdentifier == ToolbarSeparatorDelegate.separator else { return }
                        DispatchQueue.main.async { self?.apply(in: self?.window) }
                    }
                }
            }

            private func installSeparator(in window: NSWindow, splitView: NSSplitView) {
                guard let toolbar = window.toolbar else { return }
                self.window = window
                observe(toolbar)
                if let current = toolbar.delegate, current !== delegate {
                    delegate = ToolbarSeparatorDelegate(original: current, splitView: splitView)
                    toolbar.delegate = delegate
                }
                delegate?.splitView = splitView
                let ids = toolbar.items.map(\.itemIdentifier)
                guard !ids.contains(ToolbarSeparatorDelegate.separator) else { return }
                // Right after SwiftUI's sidebar separator, so every item after it
                // (Follow and Close) is in the thread's section.
                let after = toolbar.items.firstIndex { $0 is NSTrackingSeparatorToolbarItem }
                    .map { $0 + 1 } ?? 0
                toolbar.insertItem(withItemIdentifier: ToolbarSeparatorDelegate.separator, at: after)
                toolbar.insertItem(withItemIdentifier: .flexibleSpace, at: after + 1)
            }

            private func setOpen(_ open: Bool, in controller: NSSplitViewController) {
                let content = controller.splitViewItems[1]
                let thread = controller.splitViewItems[2]
                content.minimumThickness = ThreadColumnLayout.minimumWidth
                thread.minimumThickness = ThreadColumnLayout.minimumWidth
                thread.canCollapse = true
                guard open == thread.isCollapsed else { return }
                if !open {
                    if hasOpened {
                        rememberedWidth = thread.viewController.view.frame.width
                    }
                    thread.isCollapsed = true
                    return
                }
                hasOpened = true
                thread.isCollapsed = false
                let split = controller.splitView
                split.layoutSubtreeIfNeeded()
                // What the conversation and the thread share: from the
                // conversation's leading edge to the window's trailing one.
                let leading = content.viewController.view.frame.minX
                let available = split.bounds.width - leading - split.dividerThickness
                let width = ThreadColumnLayout.openingWidth(available: available, remembered: rememberedWidth)
                split.setPosition(split.bounds.width - width - split.dividerThickness, ofDividerAt: 1)
            }
        }
    }

    /// SwiftUI's toolbar delegate, with one item added: the thread column's
    /// tracking separator. Everything else is forwarded to SwiftUI.
    final class ToolbarSeparatorDelegate: NSObject, NSToolbarDelegate {
        static let separator = NSToolbarItem.Identifier("kibble.threadColumnSeparator")
        let original: NSToolbarDelegate
        weak var splitView: NSSplitView?

        init(original: NSToolbarDelegate, splitView: NSSplitView) {
            self.original = original
            self.splitView = splitView
        }

        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || original.responds(to: selector)
        }

        override func forwardingTarget(for _: Selector!) -> Any? {
            original
        }

        func toolbar(
            _ toolbar: NSToolbar,
            itemForItemIdentifier identifier: NSToolbarItem.Identifier,
            willBeInsertedIntoToolbar flag: Bool
        ) -> NSToolbarItem? {
            if identifier == Self.separator, let splitView {
                return NSTrackingSeparatorToolbarItem(
                    identifier: identifier,
                    splitView: splitView,
                    dividerIndex: 1
                )
            }
            return original.toolbar?(
                toolbar,
                itemForItemIdentifier: identifier,
                willBeInsertedIntoToolbar: flag
            )
        }

        func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            (original.toolbarAllowedItemIdentifiers?(toolbar) ?? []) + [Self.separator, .flexibleSpace]
        }

        func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            original.toolbarDefaultItemIdentifiers?(toolbar) ?? []
        }
    }
#endif
