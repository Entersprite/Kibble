#if os(macOS)
    import AppKit
    import ChatKit
    import SwiftUI
    import Testing
    @testable import DesignSystem

    @MainActor
    @Suite(.enabled(if: visibleUITestsEnabled), .serialized, .timeLimit(.minutes(1)))
    struct PinnedMessageHostedTests {
        @Test(arguments: [false, true], ["go-to-pinned-message", "pinned-message-content"])
        func expansionWaitsForTheMessageOrNavigationButton(dark: Bool, target: String) async throws {
            let (message, state) = pinState()
            var opened: [MessageAddress] = []
            var actions = ChatSceneActions()
            actions.openMessageReference = { opened.append($0) }
            let host = hosted(state: state, actions: actions, width: 420, dark: dark)
            let window = hostedWindow(host)
            defer { window.close() }
            try await wait { find("pin-checklist") != nil }
            #expect(find("pin-another-pin") == nil)
            let pinButton = try #require(find("pins-menu"))
            #expect(press(pinButton))
            try await wait { find("pin-another-pin") != nil }
            #expect(opened.isEmpty)
            // Disclosed under the row, never over it (screen coordinates rise upward).
            let disclosed = try frame(#require(find("pin-another-pin")))
            #expect(try disclosed.maxY <= frame(#require(find("pin-checklist"))).minY)
            #expect(press(pinButton))
            try await wait { find("pin-another-pin") == nil }
            try capture(host, name: "collapsed-\(dark ? "dark" : "light")")
            let bubble = try #require(find("pin-checklist"))
            #expect(press(bubble))
            try await wait { find("go-to-pinned-message") != nil }
            #expect(opened.isEmpty)
            // The message opens in a popover, a window of its own, never in the row's.
            #expect(find("expanded-pin-preview", in: host) == nil)
            let go = try #require(find(target))
            #expect(press(go))
            try await wait { !opened.isEmpty }
            try await wait { find("go-to-pinned-message") == nil }
            #expect(opened == [MessageAddress(
                conversation: message.conversationID, thread: message.threadID, message: message.id
            )])
        }

        @Test func clickingTextInExpandedPreviewNavigates() async throws {
            let (message, state) = pinState()
            var opened: [MessageAddress] = []
            var actions = ChatSceneActions()
            actions.openMessageReference = { opened.append($0) }
            let host = hosted(state: state, actions: actions, width: 840)
            let window = hostedWindow(host)
            defer { window.close() }
            try await wait { find("pin-checklist") != nil }
            #expect(try press(#require(find("pin-checklist"))))
            try await wait { textView() != nil }
            let text = try #require(textView())
            text.window?.contentView?.layoutSubtreeIfNeeded()
            #expect(text.openReference != nil)
            text.setSelectedRange(NSRange(location: 0, length: 0))
            text.openReferenceAfterClick(at: 0, count: 1)
            try await wait { !opened.isEmpty }
            #expect(opened == [MessageAddress(
                conversation: message.conversationID, thread: message.threadID, message: message.id
            )])
        }

        @Test func unpinInThePopoverUnpinsForEveryoneAndCloses() async throws {
            let (message, state) = pinState()
            var unpinned: [(Bool, Message.ID)] = []
            var actions = ChatSceneActions()
            actions.openMessageReference = { _ in }
            actions.setMessagePinned = { unpinned.append(($0, $1.id)) }
            let host = hosted(state: state, actions: actions, width: 840)
            let window = hostedWindow(host)
            defer { window.close() }
            try await wait { find("pin-checklist") != nil }
            #expect(try press(#require(find("pin-checklist"))))
            try await wait { find("unpin-pinned-message") != nil }
            #expect(try press(#require(find("unpin-pinned-message"))))
            try await wait { find("expanded-pin-preview") == nil }
            #expect(unpinned.map(\.0) == [false])
            #expect(unpinned.map(\.1) == [message.id])
        }

        @Test(arguments: [420.0, 770.0, 840.0])
        func defaultPreviewsUseTheWidthWithoutWrapping(width: Double) async throws {
            let (_, state) = pinState()
            let host = hosted(state: state, actions: ChatSceneActions(), width: width)
            let window = hostedWindow(host)
            defer { window.close() }
            try await wait { find("pin-checklist") != nil }
            let expected = width < 600 ? 1 : 4
            let visible = state.pins.messages.filter { find("pin-\($0.id.rawValue)") != nil }
            #expect(visible.count == expected)
            if width < 600 {
                let control = try #require(find("pins-menu"))
                #expect(value("accessibilityLabel", on: control) as? String == "Pinned messages, 3 hidden")
            } else {
                #expect(find("pins-menu") == nil)
                let frames = try visible.map { try frame(#require(find("pin-\($0.id.rawValue)"))) }
                #expect((frames.map(\.maxY).max() ?? 0) - (frames.map(\.maxY).min() ?? 0) < 1)
                #expect((frames.map(\.maxX).max() ?? 0) - (frames.map(\.minX).min() ?? 0) > width - 40)
            }
        }

        @Test func previewsKeepTheirChronologicalPositionsAndShareThePinButtonsHeight() async throws {
            let (_, state) = pinState()
            var actions = ChatSceneActions()
            actions.openMessageReference = { _ in }
            let host = hosted(state: state, actions: actions, width: 700)
            let window = hostedWindow(host)
            defer { window.close() }
            try await wait { find("pin-another-pin") != nil }
            let control = try #require(find("pins-menu"))
            #expect(value("accessibilityLabel", on: control) as? String == "Pinned messages, 1 hidden")
            let ids = ["pin-checklist", "pin-another-pin", "pin-third-pin", "pins-menu"]
            let before = try ids.map { try frame(#require(find($0))) }
            for pair in zip(before, before.dropFirst()) {
                #expect(pair.0.minX < pair.1.minX)
                #expect(abs(pair.0.height - pair.1.height) < 1)
            }
            let label = try value("accessibilityLabel", on: #require(find("pin-checklist"))) as? String
            #expect(label?.hasPrefix("Pinned message from Alex Lee, ") == true)
            #expect(try press(#require(find("pin-another-pin"))))
            try await wait { find("expanded-pin-preview") != nil }
            let after = try ids.map { try frame(#require(find($0))) }
            for pair in zip(before, after) {
                #expect(abs(pair.0.minX - pair.1.minX) < 1)
                #expect(abs(pair.0.minY - pair.1.minY) < 1)
            }
        }

        @Test func theRowInsetsTheTranscriptSoItsTopIsNotCovered() async throws {
            let (_, state) = pinState()
            let content = ScrollView {
                VStack(spacing: 0) {
                    Text("First message").accessibilityIdentifier("first-row")
                    ForEach(0 ..< 60, id: \.self) { Text("Row \($0)") }
                }
                .frame(maxWidth: .infinity)
            }
            let host = NSHostingView(rootView: content
                .modifier(PinnedMessageBubbles(state: state, actions: ChatSceneActions()))
                .frame(width: 840, height: 520))
            host.frame = NSRect(x: 0, y: 0, width: 840, height: 520)
            let window = hostedWindow(host)
            defer { window.close() }
            try await wait { find("pin-checklist") != nil && find("first-row") != nil }
            let pin = try frame(#require(find("pin-checklist")))
            let first = try frame(#require(find("first-row")))
            // Screen coordinates rise upward: the first row starts below the pin.
            #expect(first.maxY <= pin.minY + 1)
        }

        @Test func aFailedRefreshOffersRetryInTheRowAndKeepsThePins() async throws {
            var (_, state) = pinState()
            state.pinsError = "The network connection was lost."
            var refreshes = 0
            var actions = ChatSceneActions()
            actions.refreshPins = { refreshes += 1 }
            let host = hosted(state: state, actions: actions, width: 840)
            let window = hostedWindow(host)
            defer { window.close() }
            try await wait { find("pins-retry") != nil }
            #expect(find("pin-checklist") != nil)
            let retry = try #require(find("pins-retry"))
            let pin = try frame(#require(find("pin-checklist")))
            #expect(try abs(frame(retry).midY - pin.midY) < 1, "Retry sits in the row")
            #expect(press(retry))
            #expect(refreshes == 1)
            state.pins.messages = []
            let empty = hosted(state: state, actions: actions, width: 840)
            let second = hostedWindow(empty)
            defer { second.close() }
            try await wait { find("pins-retry", in: empty) != nil }
        }

        @Test func expandedPreviewFitsShortMessagesAndBoundsLongMessages() async throws {
            let (original, state) = pinState()
            var sizes: [CGSize] = []
            for text in ["Okay", String(repeating: "A line of release notes.\n", count: 100)] {
                var message = original
                message.text = text
                var measured = CGSize.zero
                let host = NSHostingView(rootView: PinnedMessagePopover(
                    message: message, state: state, actions: ChatSceneActions(), navigate: {}, unpin: {}
                )
                .fixedSize()
                .onGeometryChange(for: CGSize.self) { $0.size } action: { measured = $0 })
                host.frame = NSRect(x: 0, y: 0, width: 800, height: 800)
                let window = hostedWindow(host)
                try await wait { measured.height > 0 }
                sizes.append(measured)
                window.close()
            }
            #expect(sizes[0].height < 220)
            #expect(sizes[0].width < 600)
            #expect(sizes[1].height > sizes[0].height + 50)
            #expect(sizes[1].height <= 420 + 120)
            #expect(sizes[1].width <= 600 + 28 + 1)
        }
    }

    /// Hosting, finding and pressing, through accessibility as VoiceOver would.
    extension PinnedMessageHostedTests {
        private func hosted(
            state: ChatSceneState, actions: ChatSceneActions, width: Double, dark: Bool = false
        ) -> NSHostingView<some View> {
            let host = NSHostingView(rootView: Color(nsColor: .windowBackgroundColor)
                .modifier(PinnedMessageBubbles(state: state, actions: actions))
                .frame(width: width, height: 520))
            host.frame = NSRect(x: 0, y: 0, width: width, height: 520)
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            return host
        }

        /// The popover's own text view: other suites' windows can be open beside it.
        private func textView() -> BubbleTextView? {
            NSApplication.shared.windows.lazy.compactMap { window -> BubbleTextView? in
                guard window.isVisible, let content = window.contentView,
                      find("expanded-pin-preview", in: content) != nil
                else { return nil }
                return textView(in: content)
            }.first
        }

        private func textView(in view: NSView) -> BubbleTextView? {
            if let text = view as? BubbleTextView {
                return text
            }
            return view.subviews.lazy.compactMap { textView(in: $0) }.first
        }

        private func hostedWindow(_ host: NSView) -> NSWindow {
            NSApplication.shared.accessibilitySetValue(
                true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
            )
            let window = NSWindow(
                contentRect: host.frame,
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.appearance = host.appearance
            window.contentView = host
            window.orderFront(nil)
            return window
        }

        private func frame(_ node: NSObject) throws -> CGRect {
            let selector = NSSelectorFromString("accessibilityFrame")
            try #require(node.responds(to: selector))
            let get = unsafeBitCast(
                node.method(for: selector), to: (@convention(c) (AnyObject, Selector) -> CGRect).self
            )
            return get(node, selector)
        }

        private func pinState() -> (Message, ChatSceneState) {
            let message = Message(
                id: .init("checklist"), conversationID: .init("studio"), threadID: .init("topic"),
                sender: .init("alex"),
                text: "Release checklist\n\nConfirm the final artwork and review the release notes." +
                    "\n\nPlease keep any feedback in this thread.",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
            var another = message
            another.id = .init("another-pin")
            another.text = "A second pin stays behind the pin button."
            another.createdAt = message.createdAt.addingTimeInterval(-60)
            var state = ChatSceneState()
            state.capabilities.extendedFlags.insert("messagePins")
            var third = message
            third.id = .init("third-pin")
            third.text = "A third pinned message."
            third.createdAt = message.createdAt.addingTimeInterval(-120)
            var fourth = message
            fourth.id = .init("fourth-pin")
            fourth.text = "A fourth pinned message."
            fourth.createdAt = message.createdAt.addingTimeInterval(-180)
            state.pins = PinnedMessages(
                messages: [third, message, fourth, another], members: [Member(
                    id: .init("alex"),
                    kind: .human,
                    displayName: "Alex Lee"
                )],
                canModify: true
            )
            return (message, state)
        }

        private func wait(_ condition: () -> Bool) async throws {
            for _ in 0 ..< 300 {
                pump()
                if condition() {
                    return
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(condition())
        }

        private func pump() {
            RunLoop.main.run(until: Date().addingTimeInterval(0.002))
        }

        /// In any of the app's windows: a popover is a window of its own.
        private func find(_ id: String) -> NSObject? {
            NSApplication.shared.windows.lazy.compactMap { window in
                window.isVisible ? window.contentView.flatMap { find(id, in: $0) } : nil
            }.first
        }

        private func find(_ id: String, in node: NSObject) -> NSObject? {
            if value("accessibilityIdentifier", on: node) as? String == id ||
                (id == "go-to-pinned-message" && value("accessibilityLabel", on: node) as? String ==
                    "Go to Message") {
                return node
            }
            return (value("accessibilityChildren", on: node) as? [NSObject] ?? [])
                .lazy.compactMap { find(id, in: $0) }.first
        }

        private func value(_ name: String, on node: NSObject) -> AnyObject? {
            let selector = NSSelectorFromString(name)
            return node.responds(to: selector) ? node.perform(selector)?.takeUnretainedValue() : nil
        }

        private func press(_ node: NSObject) -> Bool {
            let selector = NSSelectorFromString("accessibilityPerformPress")
            guard node.responds(to: selector) else { return false }
            let action = unsafeBitCast(
                node.method(for: selector), to: (@convention(c) (AnyObject, Selector) -> Bool).self
            )
            return action(node, selector)
        }

        private func capture(_ host: NSView, name: String) throws {
            guard let output = ProcessInfo.processInfo.environment["KIBBLE_PIN_RENDER_DIR"] else { return }
            host.layoutSubtreeIfNeeded()
            host.display()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: output).appendingPathComponent("\(name).png"))
        }
    }
#endif
