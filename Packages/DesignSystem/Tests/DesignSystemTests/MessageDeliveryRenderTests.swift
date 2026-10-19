#if os(macOS)
    import AppKit
    import ChatKit
    import SwiftUI
    import Testing
    @testable import DesignSystem

    @MainActor
    struct MessageDeliveryRenderTests {
        @Test func deliveryStatesRenderAtNarrowAndRegularWidths() throws {
            for width in [CGFloat(280), CGFloat(420)] {
                for dark in [false, true] {
                    let preview = VStack(spacing: 18) {
                        row(.sending)
                        row(.unconfirmed)
                        row(.failed)
                    }.padding(20).frame(width: width).background(.background)
                        .environment(\.colorScheme, dark ? .dark : .light)
                    let host = NSHostingView(rootView: preview)
                    host.frame.size = host.fittingSize
                    let window = NSWindow(
                        contentRect: host.frame,
                        styleMask: [.titled],
                        backing: .buffered,
                        defer: true
                    )
                    window.contentView = host
                    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    host.layoutSubtreeIfNeeded()
                    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                    #expect(host.frame.width == width)
                    #expect(host.frame.height > 150)
                    if let output = ProcessInfo.processInfo.environment["KIBBLE_DELIVERY_RENDER_DIR"] {
                        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                        host.cacheDisplay(in: host.bounds, to: bitmap)
                        let bytes = try #require(bitmap.representation(using: .png, properties: [:]))
                        try bytes.write(to: URL(fileURLWithPath: output)
                            .appendingPathComponent("delivery-\(Int(width))-\(dark ? "dark" : "light").png"))
                    }
                    withExtendedLifetime(window) {}
                }
            }
        }

        private func row(_ status: MessageDeliveryStatus) -> some View {
            let message = Message(
                id: Message.ID(status.rawValue),
                conversationID: Conversation.ID("conversation"),
                threadID: MessageThread.ID("thread"),
                sender: Member.ID("self"),
                text: "Will this message arrive?",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
            var state = ChatSceneState(me: message.sender, messages: [message])
            state.messageDeliveryStatuses[message.id] = status
            return MessageBubble(
                message: message,
                state: MessageRowState(message: message, scene: state),
                checkDelivery: { _ in }
            )
        }
    }
#endif
