#if os(macOS)
    import AppKit
    import ChatKit
    import SwiftUI
    import Testing
    @testable import DesignSystem

    @MainActor
    @Suite(.serialized)
    struct MessageListHostedTests {
        private let conversation = Conversation.ID("hosted-transcript")

        private func messages(_ range: Range<Int>) -> [Message] {
            range.map { index in
                Message(
                    id: Message.ID("row-\(index)"), conversationID: conversation,
                    threadID: MessageThread.ID("thread"), sender: Member.ID("sender"),
                    text: "Message \(index): " + String(repeating: "wrapping words ", count: index % 5 + 1),
                    createdAt: Date(timeIntervalSince1970: Double(index))
                )
            }
        }

        private func state(_ range: Range<Int>) -> ChatSceneState {
            ChatSceneState(selected: conversation, messages: messages(range))
        }

        private func host(_ state: ChatSceneState) -> (NSWindow, NSHostingView<MessageList>) {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 380),
                styleMask: [.titled], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: MessageList(state: state))
            window.contentView = host
            window.orderFront(nil)
            window.displayIfNeeded()
            return (window, host)
        }

        private func texts(in view: NSView) -> [BubbleTextView] {
            (view as? BubbleTextView).map { [$0] } ?? view.subviews.flatMap(texts(in:))
        }

        private func scrollView(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView {
                return scroll
            }
            return view.subviews.lazy.compactMap(scrollView(in:)).first
        }

        private func settle(_ host: NSView, until condition: () -> Bool) async -> Bool {
            for _ in 0 ..< 100 {
                host.layoutSubtreeIfNeeded()
                if condition() {
                    return true
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return false
        }

        private func offset(of prefix: String, host: NSView, scroll: NSScrollView) -> CGFloat? {
            texts(in: host).first(where: { $0.string.hasPrefix(prefix) }).map {
                $0.convert($0.bounds, to: scroll.contentView).midY - scroll.contentView.bounds.minY
            }
        }

        private func capture(_ host: NSView, name: String) {
            guard let path = ProcessInfo.processInfo.environment["KIBBLE_RENDER_CAPTURE_DIR"],
                  let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            if let png = bitmap.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: path).appendingPathComponent("\(name).png"))
            }
        }

        @Test func firstPopulatedLayoutStartsAtTheBottomAndDelayedHistoryDoesToo() async throws {
            let (window, host) = host(state(0 ..< 100))
            defer { window.close() }
            let scroll = try #require(scrollView(in: host))
            let atBottom = await settle(host) {
                guard let document = scroll.documentView else { return false }
                return document.frame.height > 1000
                    && document.frame.height - scroll.documentVisibleRect.maxY < 14
            }
            #expect(
                atBottom,
                "The newest message should be visible on first layout"
            )
            capture(host, name: "initial-bottom")
            let (delayedWindow, delayedHost) = self.host(state(0 ..< 0))
            defer { delayedWindow.close() }
            let delayedScroll = try #require(scrollView(in: delayedHost))
            _ = await settle(delayedHost) { delayedScroll.documentView?.frame.height ?? 1 < 100 }
            delayedHost.rootView = MessageList(state: state(0 ..< 100))
            #expect(await settle(delayedHost) {
                guard let document = delayedScroll.documentView else { return false }
                return document.frame.height > 1000
                    && document.frame.height - delayedScroll.documentVisibleRect.maxY < 14
            })
        }

        @Test func searchCentersItsTargetAndPagingPreservesAnAnchor() async throws {
            var state = state(100 ..< 200)
            state.scrollTarget = Message.ID("row-150")
            let (window, host) = host(state)
            defer { window.close() }
            let scroll = try #require(scrollView(in: host))
            #expect(await settle(host) { scroll.documentVisibleRect.minY > 200 })
            let before = scroll.documentVisibleRect.minY
            let targetOffset = try #require(offset(of: "Message 150:", host: host, scroll: scroll))
            #expect(abs(targetOffset - scroll.contentView.bounds.height / 2) < 30)
            state.messages = messages(0 ..< 200)
            host.rootView = MessageList(state: state)
            #expect(
                await settle(host) { scroll.documentVisibleRect.minY > before + 1000 },
                "before: \(before), after: \(scroll.documentVisibleRect.minY)"
            )
            // New arrivals while reading the middle must leave that reading
            // position alone, including an already honoured search target.
            #expect(
                await settle(host) {
                    guard let offset = offset(of: "Message 150:", host: host, scroll: scroll)
                    else { return false }
                    return abs(offset - targetOffset) < 2
                },
                "The reading target should stay at its original pixel offset"
            )
            capture(host, name: "after-prepend")
            let afterPrepend = scroll.documentVisibleRect.minY
            let priorHeight = scroll.documentView?.frame.height ?? 0
            state.messages.append(contentsOf: messages(200 ..< 201))
            host.rootView = MessageList(state: state)
            #expect(await settle(host) {
                (scroll.documentView?.frame.height ?? 0) > priorHeight + 5
                    && abs(scroll.documentVisibleRect.minY - afterPrepend) < 2
            })
        }

        @Test func bidirectionalWindowTrimmingKeepsTheSameMessageAtTheSameOffset() async throws {
            var state = state(100 ..< 600)
            state.scrollTarget = Message.ID("row-350")
            state.hasOlderMessages = true
            state.hasNewerMessages = true
            let (window, host) = host(state)
            defer { window.close() }
            let scroll = try #require(scrollView(in: host))
            #expect(await settle(host) {
                guard let offset = offset(of: "Message 350:", host: host, scroll: scroll)
                else { return false }
                return abs(offset - scroll.contentView.bounds.height / 2) < 30
            })
            let startingOffset = try #require(offset(of: "Message 350:", host: host, scroll: scroll))
            for range in [0 ..< 500, 100 ..< 600, 0 ..< 500, 100 ..< 600] {
                let previousOrigin = scroll.documentVisibleRect.minY
                state.messages = messages(range)
                host.rootView = MessageList(state: state)
                #expect(
                    await settle(host) {
                        guard let offset = offset(of: "Message 350:", host: host, scroll: scroll)
                        else { return false }
                        return abs(scroll.documentVisibleRect.minY - previousOrigin) > 1000
                            && abs(offset - startingOffset) < 2
                    },
                    "Paging \(range) should preserve the current reading position"
                )
            }
            capture(host, name: "after-bidirectional-trim")
        }

        @Test(arguments: [2000 ..< 2100, 140 ..< 240, 100 ..< 200])
        func explicitLatestJumpOpensAtTheBottomForDisjointAndOverlappingWindows(
            latest: Range<Int>
        ) async throws {
            var state = state(100 ..< 200)
            state.scrollTarget = Message.ID("row-150")
            state.hasNewerMessages = true
            state.newerMessagesAreLatestJump = true
            let (window, host) = host(state)
            defer { window.close() }
            let scroll = try #require(scrollView(in: host))
            var requests = 0
            host.rootView = MessageList(state: state, loadNewerMessages: { requests += 1 })
            #expect(await settle(host) { scroll.documentVisibleRect.minY > 200 })
            #expect(requests == 0)
            scroll.contentView.scroll(to: NSPoint(
                x: 0,
                y: (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height
            ))
            scroll.reflectScrolledClipView(scroll.contentView)
            #expect(await settle(host) {
                guard let document = scroll.documentView else { return false }
                let bottom = document.frame.height - scroll.contentView.bounds.height
                scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom))
                scroll.reflectScrolledClipView(scroll.contentView)
                return abs(document.frame.height - scroll.documentVisibleRect.maxY) < 2
            })
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(
                    with: type, location: NSPoint(x: 240, y: 22), modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                    pressure: 1
                ))
                window.sendEvent(event)
            }
            #expect(await settle(host) { requests == 1 })
            state.isLoadingNewerMessages = true
            host.rootView = MessageList(state: state, loadNewerMessages: { requests += 1 })
            // A late server response changes both history and its height.
            state.messages = messages(latest)
            state.scrollTarget = nil
            state.isLoadingNewerMessages = false
            state.hasNewerMessages = false
            state.newerMessagesAreLatestJump = false
            host.rootView = MessageList(state: state, loadNewerMessages: { requests += 1 })
            #expect(await settle(host) {
                guard let document = scroll.documentView,
                      let newest = offset(of: "Message \(latest.upperBound - 1):", host: host, scroll: scroll)
                else { return false }
                return document.frame.height - scroll.documentVisibleRect.maxY < 14
                    && newest < scroll.contentView.bounds.height
            })
            #expect(requests == 1)
        }
    }
#endif
