#if os(macOS)
    import AppKit
    import ChatKit
    import SwiftUI
    import Testing
    @testable import DesignSystem

    @MainActor
    @Suite(.enabled(if: visibleUITestsEnabled), .serialized)
    struct ScheduledMessagesRenderTests {
        @Test(arguments: [false, true])
        func queuedRowsAndTheComposerRenderAtCompactWidth(_ dark: Bool) async throws {
            let conversation = Conversation(id: .init("design"), kind: .space, title: "Design Team")
            let message = ScheduledMessage(
                id: ScheduledMessageAddress(conversation: conversation.id, thread: nil, queueID: "test"),
                body: ComposedMessage(text: "Share the final design notes."),
                deliveryTime: Date(timeIntervalSince1970: 1_800_000_000), deliveryFailed: true
            )
            let file = ScheduledMessage(
                id: .init(conversation: conversation.id, thread: nil, queueID: "file"),
                body: .init(text: ""), deliveryTime: message.deliveryTime,
                attachmentNames: ["Design.pdf", "Preview.png"]
            )
            var state = ChatSceneState(conversations: [conversation])
            state.scheduled.messages = [file, message]
            state.scheduled.hasMore = true
            var submission: ComposedMessage?
            let actions = ScheduledMessagesActions(
                show: {}, refresh: {}, loadMore: {}, submit: { _, body, _, _ in
                    submission = body
                    return true
                },
                latestReceipt: { _ in nil }, edit: { _, _, _ in true },
                reschedule: { _, _, _ in true }, cancel: { _ in }
            )
            var draft = ComposerDraft()
            draft.edit("A new scheduled update")
            let content = VStack {
                ScheduledMessagesPane(state: state, actions: actions)
                Composer(
                    placeholder: "Design Team", initialDraft: draft,
                    scheduling: actions.composer(
                        at: ComposerDraftAddress(conversation: conversation.id), scene: state.scheduled
                    ),
                    send: { _ in }
                )
            }
            .environment(\.colorScheme, dark ? .dark : .light)
            .frame(width: 360, height: 295)
            let host = NSHostingView(rootView: content)
            let window = show(host, dark: dark)
            defer { close(window) }
            for _ in 0 ..< 10 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(host.frame.size == CGSize(width: 360, height: 295))
            try render(host, dark: dark)
            if !dark {
                try await submitFromClock(in: window)
                #expect(submission?.text == "A new scheduled update")
            }
        }

        private func show(_ host: NSView, dark: Bool) -> NSWindow {
            let bounds = NSRect(x: 0, y: 0, width: 360, height: 295)
            let window = NSWindow(contentRect: bounds, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = host
            window.orderFront(nil)
            return window
        }

        private func close(_ window: NSWindow) {
            if let sheet = window.attachedSheet {
                window.endSheet(sheet)
            }
            window.close()
        }

        private func render(_ host: NSView, dark: Bool) throws {
            if let directory = ProcessInfo.processInfo.environment["KIBBLE_SCHEDULED_RENDER_DIR"] {
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try #require(bitmap.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: directory).appendingPathComponent(
                        dark ? "scheduled-dark.png" : "scheduled-light.png"
                    ))
            }
        }

        private func submitFromClock(in window: NSWindow) async throws {
            // Found by its name, not at a fixed point: the button's place
            // depends on what else sits in the field.
            let host = try #require(window.contentView)
            let button = try #require(find("Schedule Send…", in: host))
            let onScreen = try frame(button)
            let location = window.convertPoint(
                fromScreen: NSPoint(x: onScreen.midX, y: onScreen.midY)
            )
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(
                    with: type, location: location, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                    pressure: 1
                ))
                window.sendEvent(event)
            }
            for _ in 0 ..< 100 where window.attachedSheet == nil {
                try await Task.sleep(for: .milliseconds(10))
            }
            let sheet = try #require(window.attachedSheet)
            let enter = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: sheet.windowNumber, context: nil, characters: "\r",
                charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36
            ))
            if !sheet.performKeyEquivalent(with: enter) {
                sheet.sendEvent(enter)
            }
            for _ in 0 ..< 100 where window.attachedSheet != nil {
                try await Task.sleep(for: .milliseconds(10))
            }
        }

        private func find(_ label: String, in node: NSObject) -> NSObject? {
            if value("accessibilityLabel", on: node) as? String == label {
                return node
            }
            return (value("accessibilityChildren", on: node) as? [NSObject] ?? [])
                .lazy.compactMap { find(label, in: $0) }.first
        }

        private func value(_ name: String, on node: NSObject) -> AnyObject? {
            let selector = NSSelectorFromString(name)
            return node.responds(to: selector) ? node.perform(selector)?.takeUnretainedValue() : nil
        }

        private func frame(_ node: NSObject) throws -> CGRect {
            let selector = NSSelectorFromString("accessibilityFrame")
            try #require(node.responds(to: selector))
            let get = unsafeBitCast(
                node.method(for: selector), to: (@convention(c) (AnyObject, Selector) -> CGRect).self
            )
            return get(node, selector)
        }
    }
#endif
