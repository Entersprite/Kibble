#if os(macOS)
    import AppKit
    import ChatKit
    import SwiftUI
    import Testing
    @testable import DesignSystem

    @MainActor
    @Suite(.serialized, .timeLimit(.minutes(1)))
    struct PinnedMessageNavigationHostedTests {
        @Test func repeatedPinJumpsRenderTheTargetInEachReplacementWindow() async {
            func message(_ index: Int) -> Message {
                Message(
                    id: .init("pin-row-\(index)"), conversationID: .init("pins"),
                    threadID: .init("thread-\(index)"), sender: .init("peer"),
                    text: "Pinned history \(index): " + String(
                        repeating: "variable height ",
                        count: index % 9 + 1
                    ),
                    createdAt: Date(timeIntervalSince1970: Double(index) * 600)
                )
            }
            let harness = TranscriptFollowHostedTests.Harness(ChatSceneState(
                messages: (900 ..< 1000).map(message)
            ))
            defer { harness.window.close() }
            #expect(await harness.settle { harness.newestGap != nil })
            for lower in [0, 450, 900, 450] {
                let target = message(lower + 50)
                harness.state.scrollTarget = target.id
                harness.state.searchOpenGeneration += 1
                harness.state.isLoadingScrollTarget = true
                harness.show()
                await Task.yield()
                harness.state.messages = (lower ..< lower + 100).map(message)
                harness.state.isLoadingScrollTarget = false
                harness.state.hasNewerMessages = true
                harness.show()
                #expect(await harness.settle {
                    guard let frame = harness.frame(of: 50), let scroll = harness.scroll else { return false }
                    return frame.maxY > 0 && frame.minY < scroll.contentView.bounds.height
                        && abs(frame.midY - scroll.contentView.bounds.height / 2) < 80
                }, "The selected pinned message must render near the center")
            }
        }
    }
#endif
