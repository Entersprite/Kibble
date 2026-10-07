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
        /// Opens the picker from the native menu's "More Emoji…".
        var onMore: (() -> Void)?
        /// Edit… and Delete… for the person's own message (edit spec §5).
        var own: OwnMessageMenuItems?
        /// Your own bubble draws links white; anyone else's, accent.
        var inOwnBubble = false
        /// Opens a clicked link that `LinkPolicy` allows (links spec §7.2).
        var open: (URL) -> Void = { _ in }

        func makeCoordinator() -> Coordinator {
            Coordinator(message: message, actions: actions, onMore: onMore, own: own, open: open)
        }

        func makeNSView(context: Context) -> BubbleTextView {
            let view = BubbleTextView.make()
            view.delegate = context.coordinator
            view.insets = insets
            view.linkTextAttributes = MessageTextAttributes.linkAttributes(inOwnBubble: inOwnBubble)
            view.show(text)
            return view
        }

        func updateNSView(_ view: BubbleTextView, context: Context) {
            context.coordinator.update(
                message: message,
                actions: actions,
                onMore: onMore,
                own: own,
                open: open
            )
            view.insets = insets
            view.linkTextAttributes = MessageTextAttributes.linkAttributes(inOwnBubble: inOwnBubble)
            view.show(text)
        }

        func sizeThatFits(
            _ proposal: ProposedViewSize,
            nsView: BubbleTextView,
            context _: Context
        ) -> CGSize? {
            nsView.fittingSize(forWidth: proposal.width)
        }

        /// The delegate. It holds the message and actions of the latest update,
        /// so a menu always acts on what the bubble shows now.
        @MainActor
        final class Coordinator: NSObject, NSTextViewDelegate {
            private(set) var message: Message
            private(set) var actions: ReactionActions?
            private(set) var onMore: (() -> Void)?
            private(set) var own: OwnMessageMenuItems?
            private(set) var open: (URL) -> Void

            init(
                message: Message, actions: ReactionActions?, onMore: (() -> Void)? = nil,
                own: OwnMessageMenuItems? = nil, open: @escaping (URL) -> Void = { _ in }
            ) {
                self.message = message
                self.actions = actions
                self.onMore = onMore
                self.own = own
                self.open = open
            }

            func update(
                message: Message, actions: ReactionActions?, onMore: (() -> Void)? = nil,
                own: OwnMessageMenuItems? = nil, open: @escaping (URL) -> Void = { _ in }
            ) {
                self.message = message
                self.actions = actions
                self.onMore = onMore
                self.own = own
                self.open = open
            }

            /// Opens through `LinkPolicy`, and always answers `true`: a refused
            /// scheme is consumed here, so AppKit never opens it either.
            func textView(_: NSTextView, clickedOnLink link: Any, at _: Int) -> Bool {
                let url = (link as? URL) ?? (link as? String).flatMap { URL(string: $0) }
                if let url, LinkPolicy.canOpen(url) {
                    open(url)
                }
                return true
            }

            /// Reactions, then Edit… and Delete…, then the text's own items.
            func textView(_: NSTextView, menu: NSMenu, for _: NSEvent, at _: Int) -> NSMenu? {
                let own = message.isDeleted ? nil : own
                return NativeReactionMenu.insertReactions(
                    into: NativeOwnMessageMenu.insert(own, into: ReadingTextMenu.trimmed(menu)),
                    message: message, actions: actions, onMore: onMore
                )
            }
        }
    }

    /// A read-only, selectable, transparent text view that sizes itself to its
    /// text, with asymmetric insets. `textContainerInset` is symmetric, and the
    /// "edited" label needs a zero bottom, so the origin is overridden instead.
    final class BubbleTextView: NSTextView {
        var insets = NSEdgeInsets() {
            didSet {
                // Every SwiftUI update sets this; only a change relays out.
                guard Insets(insets) != Insets(oldValue) else { return }
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
        /// at least one line high, even when empty. `nil` or an infinite width
        /// is the ideal size, the text on as few lines as its own line breaks
        /// allow.
        ///
        /// Measured on a private TextKit stack, never the view's own:
        /// `NSTextView` puts its container back to its frame's width, so once
        /// SwiftUI has placed the view, its own layout answers for the frame
        /// rather than the text. That made short bubbles full width and clipped
        /// wrapped text after a resize (session 45 review, Critical 1). The
        /// last answer is kept, because SwiftUI asks the same question
        /// repeatedly.
        func fittingSize(forWidth width: CGFloat?) -> CGSize {
            let width = width.flatMap { $0.isFinite ? $0 : nil }
            // A copy: `attributedString()` is the live storage, and a cached
            // alias of it would match every later text (session 45 re-review).
            let text = NSAttributedString(attributedString: attributedString())
            if let last = lastMeasurement, last.width == width, last.insets == Insets(insets),
               last.text.isEqual(to: text) {
                return last.size
            }
            let horizontal = insets.left + insets.right
            let available = width.map { max(1, $0 - horizontal) } ?? CGFloat.greatestFiniteMagnitude
            let storage = NSTextStorage(attributedString: text)
            let layout = NSLayoutManager()
            storage.addLayoutManager(layout)
            let container = NSTextContainer(size: NSSize(
                width: available,
                height: CGFloat.greatestFiniteMagnitude
            ))
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            layout.ensureLayout(for: container)
            let used = layout.usedRect(for: container)
            let lineHeight = layout.defaultLineHeight(for: NSFont.preferredFont(forTextStyle: .body))
            var fitted = CGSize(
                width: (used.width + horizontal).rounded(.up),
                height: (max(used.height, lineHeight) + insets.top + insets.bottom).rounded(.up)
            )
            if let width {
                fitted.width = min(fitted.width, width)
            }
            lastMeasurement = Measurement(text: text, width: width, insets: Insets(insets), size: fitted)
            return fitted
        }

        /// `NSEdgeInsets` is not `Equatable`.
        private struct Insets: Equatable {
            let top, left, bottom, right: CGFloat

            init(_ insets: NSEdgeInsets) {
                top = insets.top
                left = insets.left
                bottom = insets.bottom
                right = insets.right
            }
        }

        private struct Measurement {
            let text: NSAttributedString
            let width: CGFloat?
            let insets: Insets
            let size: CGSize
        }

        private var lastMeasurement: Measurement?

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
