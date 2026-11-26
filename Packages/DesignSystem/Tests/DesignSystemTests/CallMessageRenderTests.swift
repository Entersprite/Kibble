#if os(macOS)
    import AppKit
    import ChatKit
    import SwiftUI
    import Testing
    @testable import DesignSystem

    @MainActor
    struct CallMessageRenderTests {
        @Test func callHistoryAndOrdinaryMessagesRenderAtNarrowAndRegularWidths() throws {
            for width in [CGFloat(280), CGFloat(480)] {
                for dark in [false, true] {
                    let preview = VStack(alignment: .leading, spacing: 14) {
                        row(nil, mine: false)
                        row(.started, mine: false)
                        row(.missed, mine: false)
                        row(.ended, mine: true)
                        row(.unknown("future"), mine: false)
                        row(.started, mine: true, deleted: true)
                    }
                    .padding(18).frame(width: width).background(.background)
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
                    #expect(host.frame.height > 250)
                    if let output = ProcessInfo.processInfo.environment["KIBBLE_CALL_CARD_RENDER_DIR"] {
                        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                        host.cacheDisplay(in: host.bounds, to: bitmap)
                        let data = try #require(bitmap.representation(using: .png, properties: [:]))
                        try data.write(to: URL(fileURLWithPath: output)
                            .appendingPathComponent("calls-\(Int(width))-\(dark ? "dark" : "light").png"))
                    }
                    withExtendedLifetime(window) {}
                }
            }
        }

        private func row(_ status: MessageCallStatus?, mine: Bool, deleted: Bool = false) -> some View {
            let message = Message(
                id: .init("message"), conversationID: .init("conversation"), threadID: .init("thread"),
                sender: .init(mine ? "self" : "peer"), text: "Ordinary chat message",
                createdAt: Date(), isDeleted: deleted, callStatus: status
            )
            let scene = ChatSceneState(directory: [
                .init("peer"): Member(id: .init("peer"), kind: .human, displayName: "Taylor")
            ], me: .init("self"), messages: [message])
            return MessageBubble(message: message, state: MessageRowState(message: message, scene: scene))
        }
    }
#endif
