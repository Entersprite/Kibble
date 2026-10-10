#if os(macOS)
    import AppKit
    import SwiftUI

    /// What SwiftUI's three-column `NavigationSplitView` does not do for the
    /// thread column, done in AppKit:
    ///
    /// 1. **No thread, no column.** The split view item is collapsed while no
    ///    thread is open, which SwiftUI cannot do for a detail column, and it
    ///    reopens at half, or at the width the person last dragged it to
    ///    (`ThreadColumnLayout`, sessions 64 and 65).
    /// 2. **The sidebar's width**, which SwiftUI does not apply in three
    ///    columns (`SidebarColumnLayout`, session 65).
    ///
    /// The thread's titlebar section, which this bridge inserted in session 64,
    /// is SwiftUI's own since session 65: SwiftUI puts a tracking separator on
    /// a divider when the columns on both sides have toolbar items, and the
    /// conversation's column always has one now, an empty spacer
    /// (`ChatWindow.body`). Without that spacer SwiftUI also removes the whole
    /// toolbar while no thread is open, and the band shrank to a 32-pt titlebar
    /// with the subtitle on the title's line. A second separator for the same
    /// divider throws ("Cannot register more than one
    /// NSTrackingSeparatorToolbarItem that tracks the same divider", traced),
    /// so the bridge adds none.
    ///
    /// Re-applied on every update and after it, because SwiftUI sets the split
    /// view items' thicknesses again on its own updates.
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
            /// The thread column's width as the person last dragged it, the only
            /// width it reopens at; anything else reopens at half (session 65).
            /// Not its width at closing: SwiftUI lays the detail column out
            /// before any thread exists, at a width nobody chose (session 64,
            /// measured: 1,027 of 1,432 pt), and a window resize moves it too.
            private var rememberedWidth: CGFloat?
            /// Set while the bridge moves a divider itself, so its own move is
            /// not taken for a drag.
            private var positioning = false
            private weak var observedSplit: NSSplitView?
            private var dividerMoves: NSObjectProtocol?

            /// A divider moved by hand posts its index, but so do a collapse and
            /// SwiftUI's own layout at launch (session 65, traced), so a move
            /// counts only during a mouse drag that is not a window resize.
            private static func isDividerDrag(in split: NSSplitView?) -> Bool {
                NSApp.currentEvent?.type == .leftMouseDragged && split?.window?.inLiveResize == false
            }

            /// A divider moved by hand posts its index (and see
            /// `isDividerDrag`). Only the thread's divider is remembered.
            private func observeDrags(of split: NSSplitView) {
                guard observedSplit !== split else { return }
                if let dividerMoves {
                    NotificationCenter.default.removeObserver(dividerMoves)
                }
                observedSplit = split
                dividerMoves = NotificationCenter.default.addObserver(
                    forName: NSSplitView.didResizeSubviewsNotification, object: split, queue: .main
                ) { [weak self] note in
                    let index = note.userInfo?["NSSplitViewDividerIndex"] as? Int
                    MainActor.assumeIsolated {
                        guard let self, !self.positioning, index == 1,
                              Self.isDividerDrag(in: self.observedSplit),
                              let items = (self.observedSplit?.delegate as? NSSplitViewController)?
                              .splitViewItems,
                              items.count == 3, !items[2].isCollapsed
                        else { return }
                        self.rememberedWidth = items[2].viewController.view.frame.width
                    }
                }
            }

            func apply(in window: NSWindow?) {
                guard let window, let frame = window.contentView?.superview,
                      let controller = Self.splitController(in: frame)
                else { return }
                sizeSidebar(in: controller)
                setOpen(isOpen, in: controller)
            }

            /// Whether the sidebar has had its width checked in this window.
            private var sidebarSized = false

            /// The sidebar's minimum, and its ideal width where it opened
            /// narrower, once per window, so a drag past the minimum is never
            /// undone (`SidebarColumnLayout`).
            private func sizeSidebar(in controller: NSSplitViewController) {
                let sidebar = controller.splitViewItems[0]
                sidebar.minimumThickness = SidebarColumnLayout.minimumWidth
                guard !sidebarSized else { return }
                let current = sidebar.viewController.view.frame.width
                guard current > 0 else { return }
                sidebarSized = true
                if let width = SidebarColumnLayout.correctedWidth(current: current) {
                    controller.splitView.setPosition(width, ofDividerAt: 0)
                }
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

            private func setOpen(_ open: Bool, in controller: NSSplitViewController) {
                let content = controller.splitViewItems[1]
                let thread = controller.splitViewItems[2]
                content.minimumThickness = ThreadColumnLayout.minimumWidth
                thread.minimumThickness = ThreadColumnLayout.minimumWidth
                thread.canCollapse = true
                // Equal, so a window resize is shared between the two rather
                // than taken by the thread alone (SwiftUI gives it the lowest).
                thread.holdingPriority = content.holdingPriority
                let split = controller.splitView
                observeDrags(of: split)
                guard open == thread.isCollapsed else { return }
                positioning = true
                defer { positioning = false }
                if !open {
                    thread.isCollapsed = true
                    return
                }
                thread.isCollapsed = false
                split.layoutSubtreeIfNeeded()
                let sidebar = controller.splitViewItems[0]
                let available = ThreadColumnLayout.sharedWidth(
                    splitWidth: split.bounds.width,
                    contentLeading: content.viewController.view.frame.minX,
                    sidebarTrailing: sidebar.isCollapsed ? nil : sidebar.viewController.view.frame.maxX,
                    divider: split.dividerThickness
                )
                let width = ThreadColumnLayout.openingWidth(available: available, remembered: rememberedWidth)
                split.setPosition(split.bounds.width - width - split.dividerThickness, ofDividerAt: 1)
            }
        }
    }
#endif
