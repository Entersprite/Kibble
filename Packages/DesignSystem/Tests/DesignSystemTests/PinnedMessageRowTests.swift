#if os(macOS)
    import AppKit
#endif
import ChatKit
import Foundation
import Testing
@testable import DesignSystem

@MainActor
struct PinnedMessageRowTests {
    private let alex = Member(id: .init("alex"), kind: .human, displayName: "Alex Lee")

    private func message(_ id: String, text: String = "Release checklist") -> Message {
        Message(
            id: .init(id), conversationID: .init("studio"), threadID: .init("topic"), sender: .init("alex"),
            text: text, createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    @Test func unpinUsesItsOwnSymbolAndBothAreNamedOnce() {
        var handlers = OwnMessageHandlers(me: .init("me"), pin: { _ in })
        let pin = MessageMenuTable(own: handlers.items(for: message("a"))).message.last
        #expect(pin?.symbol == MessageMenuSymbols.pin)
        handlers.isPinned = { _ in true }
        let unpin = MessageMenuTable(own: handlers.items(for: message("a"))).message.last
        #expect(unpin?.symbol == MessageMenuSymbols.unpin)
        #expect(MessageMenuSymbols.all.contains(MessageMenuSymbols.pin))
        #expect(MessageMenuSymbols.all.contains(MessageMenuSymbols.unpin))
        #if os(macOS)
            for name in [MessageMenuSymbols.pin, MessageMenuSymbols.unpin, PinStyle.symbol] {
                #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "\(name)")
            }
        #endif
    }

    @Test func keyboardHighlightWalksTheRowThenTheDisclosedList() {
        let row: [PinRowTarget] = [.message(.init("a")), .message(.init("b")), .more]
        let list: [PinRowTarget] = [.message(.init("c")), .message(.init("d"))]
        let closed = PinRowNavigation(row: row, list: [])
        #expect(closed.first == .message(.init("a")))
        #expect(closed.move(from: nil, forward: true) == .message(.init("a")))
        #expect(closed.move(from: .message(.init("b")), forward: true) == .more)
        #expect(closed.move(from: .more, forward: true) == .more)
        #expect(closed.move(from: .message(.init("a")), forward: false) == .message(.init("a")))
        let open = PinRowNavigation(row: row, list: list)
        #expect(open.move(from: .more, forward: true) == .message(.init("c")))
        #expect(open.move(from: .message(.init("d")), forward: true) == .message(.init("d")))
        #expect(open.move(from: .message(.init("c")), forward: false) == .more)
        // A target that left (unpinned meanwhile) restarts at the first.
        #expect(open.move(from: .message(.init("gone")), forward: true) == .message(.init("a")))
    }

    @Test func voiceOverNamesTheAuthorAndTimeOfEachPreview() {
        let label = PinnedPreviewSpeech.label(for: message("a"), directory: [alex.id: alex], me: nil)
        #expect(label.hasPrefix("Pinned message from Alex Lee, "))
        #expect(label.hasSuffix(": Release checklist"))
        let mine = PinnedPreviewSpeech.label(for: message("a"), directory: [:], me: alex.id)
        #expect(mine.hasPrefix("Pinned message from You, "))
        var attachmentOnly = message("b", text: "")
        attachmentOnly.attachments = [Attachment(
            id: "file",
            name: "plan.pdf",
            contentType: "application/pdf"
        )]
        #expect(PinnedPreviewSpeech.preview(of: attachmentOnly) == "plan.pdf")
        #expect(PinnedPreviewSpeech.preview(of: message("c", text: "one\ntwo")) == "one two")
    }

    @Test func activityRowsDrawASymbolForWhatHappened() {
        #expect(MessageActivityRow(activity: .pinnedMessage, sender: "Alex").symbol == PinStyle.symbol)
        #expect(MessageActivityRow(activity: .pinnedResource, sender: "Alex").symbol == PinStyle.symbol)
        let unknown = MessageActivityRow(activity: .unknown("future"), sender: "Alex")
        #expect(unknown.symbol != PinStyle.symbol)
        #if os(macOS)
            #expect(NSImage(systemSymbolName: unknown.symbol, accessibilityDescription: nil) != nil)
        #endif
    }

    @Test func aPinnedRowSaysSoToVoiceOver() {
        let pinned = message("a")
        var scene = ChatSceneState(directory: [alex.id: alex], messages: [pinned])
        let plain = MessageBubble(message: pinned, state: .init(message: pinned, scene: scene))
        #expect(!plain.accessibilityLabel.contains("Pinned"))
        scene.pins = PinnedMessages(messages: [pinned], members: [], canModify: true)
        let bubble = MessageBubble(message: pinned, state: .init(message: pinned, scene: scene))
        #expect(bubble.accessibilityLabel.hasSuffix(", Pinned"))
    }
}
