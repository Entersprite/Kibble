#if os(macOS)
    import AppKit
    import ChatKit
    import SwiftUI
    import Testing
    @testable import DesignSystem

    /// Following the newest message and reading back, measured in a hosted
    /// transcript under a composer-sized inset. These scrolls are unanimated,
    /// so a hosted window can complete them without a live app event loop.
    @MainActor
    @Suite(.serialized)
    struct TranscriptFollowHostedTests {
        private let conversation = Conversation.ID("hosted-follow")

        private func message(_ index: Int, text: String? = nil) -> Message {
            Message(
                id: Message.ID("row-\(index)"), conversationID: conversation,
                threadID: MessageThread.ID("thread-\(index)"), sender: Member.ID("sender"),
                text: text ?? "Message \(index): some words in a bubble",
                createdAt: Date(timeIntervalSince1970: Double(index) * 600)
            )
        }

        private func long(_ index: Int) -> String {
            "Message \(index): " + String(repeating: "a longer message that wraps ", count: 30)
        }

        /// The transcript as the window shows it: the composer below is a
        /// bottom inset the transcript scrolls under.
        struct Framed: View {
            let list: MessageList
            var composer: CGFloat = 60

            var body: some View {
                list.safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: composer) }
            }
        }

        @MainActor
        final class Harness {
            let window: NSWindow
            let host: NSHostingView<Framed>
            var state: ChatSceneState
            var composer: CGFloat = 60

            init(_ state: ChatSceneState) {
                // SwiftUI builds its virtual accessibility nodes only after
                // accessibility is requested in this test process. Those
                // nodes implement AppKit's selectors without declaring its
                // Swift protocol conformance.
                NSApplication.shared.accessibilitySetValue(
                    true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
                )
                self.state = state
                window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 480, height: 380),
                    styleMask: [.titled, .resizable], backing: .buffered, defer: false
                )
                window.isReleasedWhenClosed = false
                host = NSHostingView(rootView: Framed(list: MessageList(state: state)))
                window.contentView = host
                window.orderFront(nil)
            }

            func show() {
                host.rootView = Framed(list: MessageList(state: state), composer: composer)
            }

            var scroll: NSScrollView? {
                func find(_ view: NSView) -> NSScrollView? {
                    (view as? NSScrollView) ?? view.subviews.lazy.compactMap(find).first
                }
                return find(host)
            }

            private func texts(in view: NSView) -> [BubbleTextView] {
                (view as? BubbleTextView).map { [$0] } ?? view.subviews.flatMap(texts(in:))
            }

            /// A message's text frame in the viewport, from its top.
            func frame(of index: Int) -> CGRect? {
                guard let scroll else { return nil }
                return texts(in: host).first { $0.string == state.messages[index].text }.map {
                    $0.convert($0.bounds, to: scroll.contentView)
                        .offsetBy(dx: 0, dy: -scroll.contentView.bounds.minY)
                }
            }

            /// A message whose text is on screen, below the top.
            var visibleRow: Int? {
                guard let scroll else { return nil }
                return state.messages.indices.first { index in
                    frame(of: index)
                        .map { $0.minY > 20 && $0.maxY < scroll.contentView.bounds.height - 80 } ?? false
                }
            }

            /// How far above the composer the newest message's text ends; `nil`
            /// while it is not on screen.
            var newestGap: CGFloat? {
                guard let scroll, let index = state.messages.indices.last,
                      let frame = frame(of: index) else { return nil }
                return scroll.contentView.bounds.height - scroll.contentInsets.bottom - frame.maxY
            }

            func settle(until condition: () -> Bool) async -> Bool {
                for _ in 0 ..< 100 {
                    host.layoutSubtreeIfNeeded()
                    if condition() {
                        return true
                    }
                    try? await Task.sleep(for: .milliseconds(10))
                }
                return false
            }

            func settle() async {
                _ = await settle { false }
            }

            /// Trackpad scrolling: positive `delta` moves toward older messages.
            func wheel(_ delta: Int32, events: Int = 12) async throws {
                let scroll = try #require(scroll)
                let point = window.convertPoint(toScreen: NSPoint(x: 240, y: 200))
                let screen = try #require(NSScreen.screens.first)
                for index in 0 ... events {
                    let event = try #require(CGEvent(
                        scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                        wheel1: index == events ? 0 : delta, wheel2: 0, wheel3: 0
                    ))
                    event.location = CGPoint(x: point.x, y: screen.frame.maxY - point.y)
                    event.setIntegerValueField(
                        .mouseEventWindowUnderMousePointer,
                        value: Int64(window.windowNumber)
                    )
                    event.setIntegerValueField(
                        .mouseEventWindowUnderMousePointerThatCanHandleThisEvent,
                        value: Int64(window.windowNumber)
                    )
                    event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                    // Began, changed, ended.
                    event.setIntegerValueField(
                        .scrollWheelEventScrollPhase, value: index == 0 ? 1 : index == events ? 4 : 2
                    )
                    try scroll.scrollWheel(with: #require(NSEvent(cgEvent: event)))
                    try await Task.sleep(for: .milliseconds(5))
                }
                await settle()
            }

            /// The floating jump, while it shows: hidden from accessibility
            /// otherwise.
            var jump: NSObject? {
                func find(_ element: Any) -> NSObject? {
                    guard let element = element as? NSObject else { return nil }
                    let label = Self.value("accessibilityLabel", on: element) as? String ?? ""
                    if label == JumpToLatestButton.title(unseen: false)
                        || label == JumpToLatestButton.title(unseen: true) {
                        return element
                    }
                    return (Self.value("accessibilityChildren", on: element) as? [Any] ?? [])
                        .lazy.compactMap(find).first
                }
                return find(host)
            }

            private static func value(_ name: String, on node: NSObject) -> AnyObject? {
                let selector = NSSelectorFromString(name)
                return node.responds(to: selector) ? node.perform(selector)?.takeUnretainedValue() : nil
            }

            func press(_ node: NSObject) -> Bool {
                let selector = NSSelectorFromString("accessibilityPerformPress")
                guard node.responds(to: selector) else { return false }
                let action = unsafeBitCast(
                    node.method(for: selector), to: (@convention(c) (AnyObject, Selector) -> Bool).self
                )
                return action(node, selector)
            }

            func close() {
                window.close()
            }
        }

        private func following(_ count: Int = 40) async throws -> (Harness, CGFloat) {
            let harness = Harness(ChatSceneState(
                selected: conversation,
                messages: (0 ..< count).map { message($0) }
            ))
            #expect(await harness.settle { harness.newestGap != nil })
            await harness.settle()
            let resting = try #require(harness.newestGap)
            #expect(resting >= 0 && resting < 30, "the newest message should open at the end")
            return (harness, resting)
        }

        private func atEnd(_ harness: Harness, _ resting: CGFloat) async -> Bool {
            await harness.settle { harness.newestGap.map { abs($0 - resting) < 2 } ?? false }
        }

        @Test func anArrivalWhileFollowingStaysAtTheEnd() async throws {
            let (harness, resting) = try await following()
            defer { harness.close() }
            harness.state.messages.append(message(40))
            harness.show()
            #expect(await atEnd(harness, resting))
            // Taller than the near-the-end margin the list once relied on.
            harness.state.messages.append(message(41, text: long(41)))
            harness.show()
            #expect(await atEnd(harness, resting))
            #expect(harness.jump == nil)
        }

        /// A picture or a preview loading, reactions or an edit: growth of the
        /// newest row and of one above it.
        @Test func growthWhileFollowingStaysAtTheEnd() async throws {
            let (harness, resting) = try await following()
            defer { harness.close() }
            harness.state.messages[38].text = long(38)
            harness.show()
            #expect(await atEnd(harness, resting), "growth above the newest pushed it off")
            harness.state.messages[39].text = long(39)
            harness.state.messages[39].reactions = [Reaction(emoji: "👍", count: 1)]
            harness.show()
            #expect(await atEnd(harness, resting))
            // Still following: a later arrival is followed too.
            harness.state.messages.append(message(40))
            harness.show()
            #expect(await atEnd(harness, resting))
            #expect(harness.jump == nil)
        }

        /// The composer growing, the window resized, the thread panel taking
        /// width: none of it stops following.
        @Test func aSmallerColumnKeepsFollowing() async throws {
            let (harness, resting) = try await following()
            defer { harness.close() }
            harness.composer = 140
            harness.show()
            #expect(await atEnd(harness, resting), "a taller composer hid the newest message")
            harness.window.setContentSize(NSSize(width: 320, height: 300))
            #expect(await atEnd(harness, resting), "a smaller window hid the newest message")
            harness.state.messages.append(message(40))
            harness.show()
            #expect(await atEnd(harness, resting))
            #expect(harness.jump == nil)
        }

        /// The saved copy giving way to confirmed rows: every id changes, and
        /// the window may hold fewer.
        @Test func confirmedRowsReplacingTheSavedCopyKeepFollowing() async throws {
            let (harness, resting) = try await following()
            defer { harness.close() }
            let saved = harness.state.messages
            harness.state.messages = saved.suffix(30).map { message in
                var confirmed = message
                confirmed.id = Message.ID("confirmed-" + message.id.rawValue)
                return confirmed
            }
            harness.show()
            #expect(await atEnd(harness, resting))
            harness.state.messages.append(message(40))
            harness.show()
            #expect(await atEnd(harness, resting))
        }

        @Test func aBoundedWindowDroppingOldRowsKeepsFollowing() async throws {
            let (harness, resting) = try await following()
            defer { harness.close() }
            harness.state.messages.removeFirst(10)
            harness.state.messages.append(message(40, text: long(40)))
            harness.show()
            #expect(await atEnd(harness, resting))
            harness.state.messages.append(message(41))
            harness.show()
            #expect(await atEnd(harness, resting))
        }

        @Test func anArrivalWhileReadingBackKeepsThePlace() async throws {
            let (harness, _) = try await following()
            defer { harness.close() }
            try await harness.wheel(40)
            let row = try #require(harness.visibleRow)
            let place = try #require(harness.frame(of: row)?.minY)
            #expect(row < 36, "the wheel should have scrolled back")
            #expect(harness.jump != nil, "scrolling back should offer the jump")
            harness.state.messages.append(message(40))
            harness.state.messages.append(message(41, text: long(41)))
            harness.state.messages[39].text = long(39)
            harness.show()
            await harness.settle()
            let after = try #require(harness.frame(of: row)?.minY)
            #expect(abs(after - place) < 2, "the place being read moved by \(after - place)")
            #expect(harness.jump != nil)
        }

        @Test func jumpToNewestFollowsAgain() async throws {
            let (harness, resting) = try await following()
            defer { harness.close() }
            try await harness.wheel(40)
            let jump = try #require(harness.jump)
            #expect(harness.press(jump))
            #expect(await atEnd(harness, resting))
            #expect(await harness.settle { harness.jump == nil })
            harness.state.messages.append(message(40, text: long(40)))
            harness.show()
            #expect(await atEnd(harness, resting), "an arrival after the jump was not followed")
        }

        @Test func scrollingBackToTheEndFollowsAgain() async throws {
            let (harness, resting) = try await following()
            defer { harness.close() }
            try await harness.wheel(40)
            #expect(harness.jump != nil)
            try await harness.wheel(-80, events: 20)
            #expect(await atEnd(harness, resting))
            #expect(await harness.settle { harness.jump == nil })
            harness.state.messages.append(message(40, text: long(40)))
            harness.show()
            #expect(await atEnd(harness, resting), "an arrival after scrolling back down was not followed")
        }

        /// A notification or a mention can open the newest message itself:
        /// that is the end, so what arrives next is followed.
        @Test func openingAtTheNewestMessageFollows() async throws {
            var state = ChatSceneState(selected: conversation, messages: (0 ..< 40).map { message($0) })
            state.scrollTarget = Message.ID("row-39")
            let harness = Harness(state)
            defer { harness.close() }
            #expect(await harness.settle { harness.newestGap != nil })
            await harness.settle()
            let resting = try #require(harness.newestGap)
            harness.state.messages.append(message(40, text: long(40)))
            harness.show()
            #expect(await atEnd(harness, resting))
        }
    }
#endif
