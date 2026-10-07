#if os(macOS)
    import AppKit
    import ChatKit
    import Foundation
    import Testing
    @testable import DesignSystem

    /// `BubbleTextView` and `MessageTextView`'s coordinator: configuration,
    /// size, the menu, and what an update keeps (native text menu spec §2, §4).
    @MainActor
    struct MessageTextViewTests {
        private static let insets = NSEdgeInsets(top: 7, left: 12, bottom: 7, right: 12)

        private static func view(_ text: String, insets: NSEdgeInsets = insets) -> BubbleTextView {
            let view = BubbleTextView.make()
            view.insets = insets
            view.textStorage?.setAttributedString(
                MessageTextAttributes.attributed(text, mentions: [], links: [], me: nil, inOwnBubble: false)
            )
            return view
        }

        private static func message(isDeleted: Bool = false) -> Message {
            Message(
                id: Message.ID("m-1"), conversationID: Conversation.ID("space/s-1"),
                threadID: MessageThread.ID("t-1"), sender: Member.ID("u-1"), text: "hello",
                createdAt: Date(timeIntervalSince1970: 0), isDeleted: isDeleted
            )
        }

        private static let lineHeight: CGFloat = {
            let font = NSFont.preferredFont(forTextStyle: .body)
            return NSLayoutManager().defaultLineHeight(for: font)
        }()

        @Test func itIsSelectableReadOnlyAndTransparent() {
            let view = Self.view("hello")
            #expect(view.isSelectable)
            #expect(!view.isEditable)
            #expect(!view.drawsBackground)
            #expect(view.textContainer?.lineFragmentPadding == 0)
        }

        @Test func oneLineIsOneLineHighPlusTheInsets() {
            let size = Self.view("hello").fittingSize(forWidth: 400)
            #expect(size.height == (Self.lineHeight + 14).rounded(.up))
            #expect(size.width < 400)
            #expect(size.width > 24)
        }

        /// Review Focus 4: never wider than offered, and wrapping grows it.
        @Test func longTextWrapsWithinTheProposal() {
            let long = String(repeating: "wrapping words ", count: 20)
            let size = Self.view(long).fittingSize(forWidth: 120)
            #expect(size.width <= 120)
            #expect(size.height > Self.lineHeight * 2 + 14)
        }

        @Test func anEmptyStringStillHasALine() {
            #expect(Self.view("").fittingSize(forWidth: 400).height >= (Self.lineHeight + 14).rounded(.down))
        }

        /// The "edited" label takes the bottom padding instead.
        @Test func aZeroBottomInsetIsSevenPointsShorter() {
            let full = Self.view("hello").fittingSize(forWidth: 400)
            let edited = Self.view("hello", insets: NSEdgeInsets(top: 7, left: 12, bottom: 0, right: 12))
                .fittingSize(forWidth: 400)
            #expect(full.height - edited.height == 7)
        }

        /// Review fix (Critical 1): `NSTextView` resets its own container to
        /// its frame, so a view that has a frame must still measure the text,
        /// not the frame.
        @Test func aFramedViewStillMeasuresItsText() {
            let view = Self.view("hello")
            view.frame = NSRect(x: 0, y: 0, width: 400, height: 40)
            #expect(view.fittingSize(forWidth: 400).width < 100)
        }

        @Test func aViewFramedNarrowMeasuresShorterWhenOfferedMore() {
            let long = String(repeating: "wrapping words ", count: 20)
            let view = Self.view(long)
            let narrow = view.fittingSize(forWidth: 120)
            view.frame = NSRect(origin: .zero, size: narrow)
            let wide = view.fittingSize(forWidth: 400)
            #expect(wide.height < narrow.height)
            #expect(wide.width > narrow.width)
        }

        /// Re-review fix: the measurement cache must key on a snapshot of the
        /// text. `attributedString()` is the view's live storage, so a cached
        /// alias always matched and an edited message kept its old size.
        @Test func changedTextAtTheSameWidthIsMeasuredAgain() {
            let view = Self.view("hello")
            let before = view.fittingSize(forWidth: 400)
            view.show(MessageTextAttributes.attributed(
                String(repeating: "much longer text ", count: 10), mentions: [], links: [], me: nil,
                inOwnBubble: false
            ))
            let after = view.fittingSize(forWidth: 400)
            #expect(after.height > before.height)
        }

        /// Review fix (Minor 4): an infinite proposal is the ideal size, not
        /// the container's ten-million-point limit.
        @Test func anInfiniteProposalIsTheIdealSize() {
            let view = Self.view("hello")
            #expect(view.fittingSize(forWidth: .infinity) == view.fittingSize(forWidth: nil))
            #expect(view.fittingSize(forWidth: nil).width < 100)
        }

        /// Review fix (Important 3): a read-only bubble's menu has no editing
        /// items. Read from a real `menu(for:)`, through the delegate.
        @Test func theNativeMenuOffersReadingItemsOnly() throws {
            let coordinator = MessageTextView.Coordinator(
                message: Self.message(), actions: ReactionActions { _, _, _ in }
            )
            let view = Self.view("hello there")
            view.frame = NSRect(x: 0, y: 0, width: 300, height: 40)
            view.delegate = coordinator
            let event = try #require(NSEvent.mouseEvent(
                with: .rightMouseDown, location: NSPoint(x: 20, y: 20), modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ))
            let menu = try #require(view.menu(for: event))
            let titles = menu.items.map(\.title)
            #expect(titles.first == "React")
            #expect(titles.contains("Copy"))
            for editing in [
                "Cut",
                "Paste",
                "Paste and Match Style",
                "Font",
                "Spelling and Grammar",
                "Substitutions"
            ] {
                #expect(!titles.contains(editing), "\(editing) is still offered")
            }
            let separators = menu.items.map(\.isSeparatorItem)
            #expect(separators.last == false)
            #expect(!zip(separators, separators.dropFirst()).contains { $0 && $1 })
        }

        @Test func theTextStartsInsideTheInsets() {
            #expect(Self.view("hello").textContainerOrigin == NSPoint(x: 12, y: 7))
        }

        @Test func theMenuGetsTheReactionRowFirst() throws {
            let coordinator = MessageTextView.Coordinator(
                message: Self.message(), actions: ReactionActions { _, _, _ in }
            )
            let native = NSMenu()
            native.addItem(withTitle: "Copy", action: nil, keyEquivalent: "")
            let event = try #require(NSEvent.mouseEvent(
                with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ))
            let menu = try #require(coordinator.textView(Self.view("hello"), menu: native, for: event, at: 0))
            #expect(menu.items.first?.submenu?.presentationStyle == .palette)
        }

        /// Review Focus 1: the coordinator acts on the message it was last
        /// given, not the one it was built with.
        @Test func anUpdatedCoordinatorUsesTheNewMessage() throws {
            let coordinator = MessageTextView.Coordinator(
                message: Self.message(), actions: ReactionActions { _, _, _ in }
            )
            coordinator.update(message: Self.message(isDeleted: true), actions: coordinator.actions)
            let native = NSMenu()
            native.addItem(withTitle: "Copy", action: nil, keyEquivalent: "")
            let event = try #require(NSEvent.mouseEvent(
                with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ))
            let menu = try #require(coordinator.textView(Self.view("hello"), menu: native, for: event, at: 0))
            #expect(menu.items.map(\.title) == ["Copy"])
        }

        /// Review Focus 5: the same text again leaves a selection alone.
        @Test func theSameTextAgainKeepsTheSelection() {
            let view = Self.view("hello there")
            view.setSelectedRange(NSRange(location: 0, length: 5))
            view.show(MessageTextAttributes.attributed(
                "hello there",
                mentions: [],
                links: [],
                me: nil,
                inOwnBubble: false
            ))
            #expect(view.selectedRange() == NSRange(location: 0, length: 5))
            view.show(MessageTextAttributes.attributed(
                "changed",
                mentions: [],
                links: [],
                me: nil,
                inOwnBubble: false
            ))
            #expect(view.string == "changed")
        }

        /// Review Focus 3: a refused scheme opens nothing and is still consumed,
        /// so AppKit never opens it either.
        @Test func aClickOpensOnlyWhatThePolicyAllows() throws {
            var opened: [URL] = []
            let coordinator = MessageTextView.Coordinator(
                message: Self.message(), actions: nil, open: { opened.append($0) }
            )
            let view = NSTextView()
            #expect(try coordinator.textView(
                view,
                clickedOnLink: #require(URL(string: "javascript:alert(1)")),
                at: 0
            ))
            #expect(try coordinator.textView(
                view,
                clickedOnLink: #require(URL(string: "file:///etc/hosts")),
                at: 0
            ))
            #expect(opened.isEmpty)
            #expect(try coordinator.textView(
                view,
                clickedOnLink: #require(URL(string: "https://acme.example")),
                at: 0
            ))
            #expect(try opened == [#require(URL(string: "https://acme.example"))])
        }
    }
#endif
