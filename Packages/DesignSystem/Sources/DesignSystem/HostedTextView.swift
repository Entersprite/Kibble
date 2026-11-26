import SwiftUI

extension EnvironmentValues {
    /// True for content a panel is drawn over: the search panel and the
    /// account panel, each of which takes every click in the window while it
    /// is open. A text view there shows the pointer, not the text cursor
    /// (`HostedTextView`).
    @Entry var coveredByPanel = false
}

extension View {
    /// Marks this content as covered by a panel while `covered`, keeping any
    /// panel already covering it from further out.
    func coveredByPanel(_ covered: Bool) -> some View {
        transformEnvironment(\.coveredByPanel) { $0 = $0 || covered }
    }
}

#if os(macOS)
    import AppKit

    /// An `NSTextView` placed in SwiftUI, which shows the text cursor over
    /// its own text and nowhere else.
    ///
    /// AppKit shows a text view's text cursor across its visible rect, both
    /// through a cursor rect and through the tracking area that moves the
    /// cursor. In SwiftUI that rect was not the view's own: the container
    /// SwiftUI puts around it does not clip, so a message's text view counted
    /// the whole visible transcript as its own (measured on macOS 27), and
    /// the text cursor showed between messages and through the search panel
    /// and the account panel. Clipping to its bounds keeps it to the text.
    ///
    /// A panel SwiftUI draws over the view is invisible to AppKit, so while
    /// one is open (`coveredByPanel`) the view claims no cursor at all.
    class HostedTextView: NSTextView {
        /// False while a panel covers the view.
        var showsTextCursor = true {
            didSet {
                guard showsTextCursor != oldValue else { return }
                window?.invalidateCursorRects(for: self)
            }
        }

        override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
            super.init(frame: frameRect, textContainer: container)
            clipsToBounds = true
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) is not used")
        }

        override func resetCursorRects() {
            guard showsTextCursor else { return }
            super.resetCursorRects()
        }

        /// Covered, the cursor is whatever the view in front would show,
        /// which the responder chain decides as it would with no text here.
        override func cursorUpdate(with event: NSEvent) {
            guard showsTextCursor else {
                nextResponder?.cursorUpdate(with: event)
                return
            }
            super.cursorUpdate(with: event)
        }

        /// `NSTextView` sets the text cursor on every move over its tracking
        /// area, so a covered view must not see the move.
        override func mouseMoved(with event: NSEvent) {
            guard showsTextCursor else { return }
            super.mouseMoved(with: event)
        }
    }
#endif
