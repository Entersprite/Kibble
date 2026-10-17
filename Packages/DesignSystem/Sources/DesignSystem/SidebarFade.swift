import SwiftUI

extension View {
    /// Conversations fade into the pinned rows above them as they scroll under
    /// them (`SidebarFade`). Applied to the conversations `List`; AppKit only.
    func sidebarFade() -> some View {
        #if os(macOS)
            background { SidebarFade() }
        #else
            self
        #endif
    }
}

#if os(macOS)
    import AppKit

    /// The top 14 pt of the conversations fade into the pinned rows above
    /// them, so a row scrolling under them is not cut off in a hard line. The
    /// fade grows with the first 14 pt of scrolling, so at rest the first
    /// section's header is drawn in full.
    ///
    /// A gradient mask on the list's clip view, which holds the rows, and
    /// never on the list itself: the footer's blur is drawn by the scroll
    /// view's bottom pocket, a sibling of the clip view, and under a masked
    /// ancestor it renders as a flat gray band. SwiftUI gives no handle on a
    /// `List`'s clip view, so this view, the list's background, finds the
    /// AppKit scroll view under it. The scroll offset comes from the clip view
    /// too, so scrolling never invalidates SwiftUI state.
    struct SidebarFade: NSViewRepresentable {
        func makeNSView(context _: Context) -> FadeView {
            FadeView()
        }

        func updateNSView(_ view: FadeView, context _: Context) {
            view.attach()
        }

        static func dismantleNSView(_ view: FadeView, coordinator _: ()) {
            view.detach()
        }

        /// Draws nothing and takes no clicks; it is here to find the list.
        final class FadeView: NSView {
            static let height: CGFloat = 14

            private weak var scrollView: NSScrollView?
            private let gradient = CAGradientLayer()

            override func hitTest(_: NSPoint) -> NSView? {
                nil
            }

            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                guard window != nil else {
                    detach()
                    return
                }
                attach()
                // The list's scroll view can join the window after this view.
                DispatchQueue.main.async { [weak self] in
                    self?.attach()
                }
            }

            override func layout() {
                super.layout()
                attach()
            }

            func attach() {
                guard let window else { return }
                if let scrollView, scrollView.window === window {
                    apply()
                    return
                }
                detach()
                guard let found = listScrollView() else { return }
                scrollView = found
                let clip = found.contentView
                clip.postsBoundsChangedNotifications = true
                clip.postsFrameChangedNotifications = true
                let center = NotificationCenter.default
                center.addObserver(
                    self, selector: #selector(clipChanged), name: NSView.boundsDidChangeNotification,
                    object: clip
                )
                center.addObserver(
                    self, selector: #selector(clipChanged), name: NSView.frameDidChangeNotification,
                    object: clip
                )
                apply()
            }

            func detach() {
                guard let clip = scrollView?.contentView else { return }
                let center = NotificationCenter.default
                center.removeObserver(self, name: NSView.boundsDidChangeNotification, object: clip)
                center.removeObserver(self, name: NSView.frameDidChangeNotification, object: clip)
                if let layer = clip.layer, layer.mask === gradient {
                    layer.mask = nil
                }
                scrollView = nil
            }

            @objc private func clipChanged(_: Notification) {
                apply()
            }

            private func apply() {
                guard let scrollView, let layer = scrollView.contentView.layer else { return }
                let clip = scrollView.contentView
                let depth = min(max(clip.bounds.minY + scrollView.contentInsets.top, 0), Self.height)
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                if layer.mask !== gradient {
                    layer.mask = gradient
                }
                // A view's layer shares its coordinates, scroll offset and
                // flipping included, so the visible top is the bounds' top.
                gradient.frame = layer.bounds
                gradient.startPoint = CGPoint(x: 0.5, y: clip.isFlipped ? 0 : 1)
                gradient.endPoint = CGPoint(x: 0.5, y: clip.isFlipped ? 1 : 0)
                gradient.colors = [
                    NSColor.black.withAlphaComponent(1 - depth / Self.height).cgColor,
                    NSColor.black.cgColor
                ]
                gradient.locations = [
                    0,
                    NSNumber(value: Double(Self.height / max(layer.bounds.height, Self.height)))
                ]
                CATransaction.commit()
            }

            /// The smallest scroll view under this view's center, searched from
            /// the nearest ancestor out: the list's own, since this view is its
            /// background.
            private func listScrollView() -> NSScrollView? {
                let center = convert(NSPoint(x: bounds.midX, y: bounds.midY), to: nil)
                var ancestor = superview
                while let current = ancestor {
                    let found = Self.scrollViews(in: current)
                        .filter { $0.convert($0.bounds, to: nil).contains(center) }
                        .min { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
                    if let found {
                        return found
                    }
                    ancestor = current.superview
                }
                return nil
            }

            private static func scrollViews(in view: NSView) -> [NSScrollView] {
                var found: [NSScrollView] = []
                for subview in view.subviews {
                    if let scrollView = subview as? NSScrollView {
                        found.append(scrollView)
                    } else {
                        found += scrollViews(in: subview)
                    }
                }
                return found
            }
        }
    }
#endif
