#if os(macOS)
    import AppKit
    import ChatKit
    import Testing
    @testable import DesignSystem

    @MainActor
    struct TranscriptReadingAnchorTests {
        private func message(_ id: Message.ID) -> Message {
            Message(
                id: id, conversationID: Conversation.ID("anchor-test"),
                threadID: MessageThread.ID("thread"), sender: Member.ID("sender"),
                text: "offline fixture", createdAt: Date(timeIntervalSince1970: 1)
            )
        }

        @Test func cancellationPreventsQueuedOffsetCorrectionFromMovingTheViewport() async {
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
            let document = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 2000))
            scroll.documentView = document
            scroll.contentView.scroll(to: NSPoint(x: 0, y: 400))
            let before = scroll.contentView.bounds.origin
            let anchor = TranscriptReadingAnchor()
            anchor.scrollView = scroll
            let id = Message.ID("visible")
            anchor.record(id, frame: CGRect(x: 0, y: -20, width: 400, height: 60))
            #expect(anchor.restore(in: [message(id)]) == id)
            anchor.beginCorrection()
            anchor.record(id, frame: CGRect(x: 0, y: 0, width: 400, height: 60))
            #expect(anchor.restoringID == id)
            anchor.cancel()
            // This main-queue item follows the queued correction; no arbitrary
            // timer is needed to prove that the cancelled callback ran safely.
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
            #expect(anchor.restoringID == nil)
            #expect(scroll.contentView.bounds.origin == before)
        }

        @Test func removedAnchorsAreDiscardedAndUnusedFailedPageCapturesCanBeRetried() {
            let anchor = TranscriptReadingAnchor()
            let id = Message.ID("visible")
            anchor.record(id, frame: CGRect(x: 0, y: -20, width: 400, height: 60))
            anchor.capture()
            anchor.discardUnusedCapture()
            anchor.record(id, frame: CGRect(x: 0, y: -10, width: 400, height: 60))
            #expect(anchor.restore(in: [message(id)]) == id)
            anchor.cancel()
            #expect(anchor.restore(in: []) == nil)
            #expect(anchor.restoringID == nil)
        }
    }
#endif
