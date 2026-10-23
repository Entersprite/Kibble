#if os(macOS)
    import AppKit
    import ChatKit
    import SwiftUI
    import Testing
    @testable import DesignSystem

    @MainActor
    @Suite(.serialized, .timeLimit(.minutes(1)))
    struct PinnedMessageHostedTests {
        @Test(arguments: [false, true], ["go-to-pinned-message", "pinned-message-content"])
        func expansionWaitsForTheMessageOrNavigationButton(dark: Bool, target: String) async throws {
            NSApplication.shared.accessibilitySetValue(
                true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
            )
            let (message, state) = pinState()
            var opened: [MessageAddress] = []
            var actions = ChatSceneActions()
            actions.openMessageReference = { opened.append($0) }
            let host = NSHostingView(rootView: ZStack {
                Color(nsColor: .windowBackgroundColor)
                PinnedMessageBubbles(state: state, actions: actions)
            }.frame(width: 420, height: 520))
            host.frame = NSRect(x: 0, y: 0, width: 420, height: 520)
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let window = NSWindow(
                contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.appearance = host.appearance
            window.contentView = host
            window.orderFront(nil)
            defer { window.close() }
            try await wait { find("pin-checklist", in: host) != nil }
            #expect(find("pin-another-pin", in: host) == nil)
            let pinButton = try #require(find("pins-menu", in: host))
            #expect(press(pinButton))
            try await wait { find("pin-another-pin", in: host) != nil }
            #expect(opened.isEmpty)
            #expect(press(pinButton))
            try await wait { find("pin-another-pin", in: host) == nil }
            try capture(host, name: "collapsed-\(dark ? "dark" : "light")")
            let bubble = try #require(find("pin-checklist", in: host))
            #expect(press(bubble))
            try await wait { find("go-to-pinned-message", in: host) != nil }
            #expect(opened.isEmpty)
            try capture(host, name: "expanded-\(dark ? "dark" : "light")")
            let go = try #require(find(target, in: host))
            #expect(press(go))
            try await wait { !opened.isEmpty }
            try await wait { find("go-to-pinned-message", in: host) == nil }
            #expect(opened == [MessageAddress(
                conversation: message.conversationID, thread: message.threadID, message: message.id
            )])
        }

        @Test func clickingTextInExpandedPreviewNavigates() async throws {
            let (message, state) = pinState()
            var opened: [MessageAddress] = []
            var actions = ChatSceneActions()
            actions.openMessageReference = { opened.append($0) }
            let host = NSHostingView(rootView: PinnedMessageBubbles(state: state, actions: actions)
                .frame(width: 840, height: 520))
            host.frame = NSRect(x: 0, y: 0, width: 840, height: 520)
            let window = hostedWindow(host)
            defer { window.close() }
            try await wait { find("pin-checklist", in: host) != nil }
            #expect(try press(#require(find("pin-checklist", in: host))))
            try await wait { textView(in: host) != nil }
            host.layoutSubtreeIfNeeded()
            let text = try #require(textView(in: host))
            #expect(text.openReference != nil)
            text.setSelectedRange(NSRange(location: 0, length: 0))
            text.openReferenceAfterClick(at: 0, count: 1)
            try await wait { !opened.isEmpty }
            #expect(opened == [MessageAddress(
                conversation: message.conversationID, thread: message.threadID, message: message.id
            )])
        }

        @Test(arguments: [420.0, 770.0, 840.0])
        func defaultPreviewsUseTheWidthWithoutWrapping(width: Double) async throws {
            NSApplication.shared.accessibilitySetValue(
                true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
            )
            let (_, state) = pinState()
            let host = NSHostingView(rootView: PinnedMessageBubbles(state: state, actions: ChatSceneActions())
                .frame(width: width, height: 520))
            host.frame = NSRect(x: 0, y: 0, width: width, height: 520)
            let window = NSWindow(
                contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFront(nil)
            defer { window.close() }
            try await wait { find("pin-checklist", in: host) != nil }
            let expected = width < 600 ? 1 : 4
            let visible = state.pins.messages.filter { find("pin-\($0.id.rawValue)", in: host) != nil }
            #expect(visible.count == expected)
            if width < 600 {
                let control = try #require(find("pins-menu", in: host))
                #expect(value("accessibilityLabel", on: control) as? String == "Pinned messages, 3 hidden")
            } else {
                #expect(find("pins-menu", in: host) == nil)
                let frames = try visible.map { try frame(#require(find("pin-\($0.id.rawValue)", in: host))) }
                #expect((frames.map(\.maxY).max() ?? 0) - (frames.map(\.maxY).min() ?? 0) < 1)
                #expect((frames.map(\.maxX).max() ?? 0) - (frames.map(\.minX).min() ?? 0) > width - 40)
            }
        }

        @Test func previewsKeepTheirChronologicalPositionsAndShareThePinButtonsHeight() async throws {
            let (_, state) = pinState()
            let host = NSHostingView(rootView: PinnedMessageBubbles(state: state, actions: ChatSceneActions())
                .frame(width: 700, height: 520))
            host.frame = NSRect(x: 0, y: 0, width: 700, height: 520)
            let window = hostedWindow(host)
            defer { window.close() }
            try await wait { find("pin-another-pin", in: host) != nil }
            let control = try #require(find("pins-menu", in: host))
            #expect(value("accessibilityLabel", on: control) as? String == "Pinned messages, 1 hidden")
            let ids = ["pin-checklist", "pin-another-pin", "pin-third-pin", "pins-menu"]
            let before = try ids.map { try frame(#require(find($0, in: host))) }
            for pair in zip(before, before.dropFirst()) {
                #expect(pair.0.minX < pair.1.minX)
                #expect(abs(pair.0.height - pair.1.height) < 1)
            }
            #expect(try press(#require(find("pin-another-pin", in: host))))
            try await wait { find("collapse-pin", in: host) != nil }
            let after = try ids.map { try frame(#require(find($0, in: host))) }
            for pair in zip(before, after) {
                #expect(abs(pair.0.minX - pair.1.minX) < 1)
                #expect(abs(pair.0.minY - pair.1.minY) < 1)
            }
        }

        @Test(arguments: [420.0, 900.0, 1400.0])
        func expandedPreviewIsCenteredAndUsesAFixedMaximumWidth(width: Double) async throws {
            var (message, state) = pinState()
            message.text = String(repeating: "A long release note with details to review. ", count: 80)
            state.pins.messages = [message]
            var actions = ChatSceneActions()
            actions.openMessageReference = { _ in }
            let host = NSHostingView(rootView: PinnedMessageBubbles(state: state, actions: actions)
                .frame(width: width, height: 520))
            host.frame = NSRect(x: 0, y: 0, width: width, height: 520)
            let window = hostedWindow(host)
            defer { window.close() }
            try await wait { find("pin-checklist", in: host) != nil }
            #expect(try press(#require(find("pin-checklist", in: host))))
            try await wait { find("expanded-pin-preview", in: host) != nil }
            let card = try frame(#require(find("expanded-pin-preview", in: host)))
            let screen = window.convertToScreen(host.convert(host.bounds, to: nil))
            #expect(abs(card.midX - screen.midX) < 1)
            #expect(abs(card.width - min(600, width - 24)) < 1)
        }

        @Test func expandedPreviewFitsShortMessagesAndBoundsLongMessages() async throws {
            let (original, state) = pinState()
            var sizes: [CGSize] = []
            for text in ["Okay", String(repeating: "A line of release notes.\n", count: 100)] {
                var message = original
                message.text = text
                var measured = CGSize.zero
                var actions = ChatSceneActions()
                actions.openMessageReference = { _ in }
                let preview = PinnedMessageBubbles(state: state, actions: actions)
                let host = NSHostingView(rootView: ContentSizedPinPreview(
                    maximumWidth: 600,
                    maximumHeight: 380
                ) {
                    preview.expandedMessage(message)
                }.onGeometryChange(for: CGSize.self) { $0.size } action: { measured = $0 })
                host.frame = NSRect(x: 0, y: 0, width: 600, height: 520)
                let window = hostedWindow(host)
                try await wait { measured.height > 0 }
                sizes.append(measured)
                window.close()
            }
            #expect(sizes[0].height < 220)
            #expect(sizes[0].width < 600)
            #expect(sizes[1].height > sizes[0].height + 50)
            #expect(sizes[1].height <= 380)
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
