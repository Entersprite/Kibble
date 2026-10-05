#if os(macOS)
    import AppKit
    import ChatKit
    import SwiftUI

    /// A message's text in an `NSTextView`, so a right-click opens the native
    /// text menu with the reaction row added (native text menu spec §2). A
    /// selectable SwiftUI `Text` brings a native menu too, but nothing found
    /// adds items to it, and it wins over a `.contextMenu` on its container.
    ///
    /// The view is the whole text bubble, padding included: the text starts at
    /// `insets` rather than being padded by SwiftUI, so a right-click anywhere
    /// on the bubble reaches this view and its menu.
    struct MessageTextView: NSViewRepresentable {
        let text: NSAttributedString
        let insets: NSEdgeInsets
        let message: Message
        let actions: ReactionActions?

        func makeCoordinator() -> Coordinator {
            Coordinator(message: message, actions: actions)
        }

        func makeNSView(context: Context) -> BubbleTextView {
            let view = BubbleTextView.make()
            view.delegate = context.coordinator
            view.insets = insets
            view.show(text)
            return view
        }

        func updateNSView(_ view: BubbleTextView, context: Context) {
            context.coordinator.update(message: message, actions: actions)
            view.insets = insets
            view.show(text)
        }

        func sizeThatFits(_ proposal: ProposedViewSize, nsView: BubbleTextView, context _: Context) -> CGSize? {
            nsView.fittingSize(forWidth: proposal.width)
        }

        /// The delegate. It holds the message and actions of the latest update,
        /// so a menu always acts on what the bubble shows now.
        @MainActor
        final class Coordinator: NSObject, NSTextViewDelegate {
            private(set) var message: Message
            private(set) var actions: ReactionActions?

            init(message: Message, actions: ReactionActions?) {
                self.message = message
                self.actions = actions
            }

            func update(message: Message, actions: ReactionActions?) {
                self.message = message
                self.actions = actions
            }

            func textView(_: NSTextView, menu: NSMenu, for _: NSEvent, at _: Int) -> NSMenu? {
                NativeReactionMenu.insertReactions(into: menu, message: message, actions: actions)
            }
        }
    }

    /// A read-only, selectable, transparent text view that sizes itself to its
    /// text, with asymmetric insets. `textContainerInset` is symmetric, and the
    /// "edited" label needs a zero bottom, so the origin is overridden instead.
    final class BubbleTextView: NSTextView {
        var insets = NSEdgeInsets() {
            didSet {
                trackFrameWidth()
                needsDisplay = true
            }
        }

        /// An explicit TextKit 1 stack: `fittingSize(forWidth:)` measures with
        /// the layout manager, and asking a TextKit 2 view for one would
        /// switch it over at that moment.
        static func make() -> BubbleTextView {
            let storage = NSTextStorage()
            let layout = NSLayoutManager()
            storage.addLayoutManager(layout)
            let container = NSTextContainer(size: NSSize(width: 1, height: CGFloat.greatestFiniteMagnitude))
            container.lineFragmentPadding = 0
            container.widthTracksTextView = false
            layout.addTextContainer(container)
            let view = BubbleTextView(frame: .zero, textContainer: container)
            view.isEditable = false
            view.isSelectable = true
            view.drawsBackground = false
            view.isVerticallyResizable = false
            view.isHorizontallyResizable = false
            view.textContainerInset = .zero
            return view
        }

        override var textContainerOrigin: NSPoint {
            NSPoint(x: insets.left, y: insets.top)
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            trackFrameWidth()
        }

        /// Replaces the text only when it changed, so a redraw for any other
        /// reason keeps the person's selection.
        func show(_ text: NSAttributedString) {
            guard let storage = textStorage, !storage.isEqual(to: text) else { return }
            storage.setAttributedString(text)
        }

        /// The size the bubble needs at `width`: never wider than offered, and
        /// at least one line high, even when empty. `nil` is the ideal size,
        /// the text on as few lines as its own line breaks allow.
        func fittingSize(forWidth width: CGFloat?) -> CGSize {
            guard let container = textContainer, let layout = layoutManager else { return .zero }
            let horizontal = insets.left + insets.right
            let tracked = container.size
            defer { container.size = tracked }
            let available = width.map { max(1, $0 - horizontal) } ?? CGFloat.greatestFiniteMagnitude
            container.size = NSSize(width: available, height: CGFloat.greatestFiniteMagnitude)
            layout.ensureLayout(for: container)
            let used = layout.usedRect(for: container)
            let lineHeight = layout.defaultLineHeight(for: NSFont.preferredFont(forTextStyle: .body))
            let fitted = CGSize(
                width: (used.width + horizontal).rounded(.up),
                height: (max(used.height, lineHeight) + insets.top + insets.bottom).rounded(.up)
            )
            guard let width else { return fitted }
            return CGSize(width: min(fitted.width, width), height: fitted.height)
        }

        /// The container is as wide as the frame minus the insets, so the text
        /// wraps where `fittingSize(forWidth:)` measured it.
        private func trackFrameWidth() {
            guard frame.width > 0 else { return }
            textContainer?.size = NSSize(
                width: max(1, frame.width - insets.left - insets.right),
                height: CGFloat.greatestFiniteMagnitude
            )
        }
    }
#endif
