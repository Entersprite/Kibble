import ChatKit
import Testing
@testable import ChatService

struct PendingPinReadTests {
    static let room = ReconciliationBackend.conversation
    static let peer = Member(id: .init("peer"), kind: .human)
    static let row = Conversation(id: room, kind: .space, members: [peer.id])
    static let pins = PinnedMessages(messages: [ReconciliationBackend.message], members: [peer])

    @Test(arguments: [
        ChatEvent.messagePinsChanged(room),
        .messageUpdated(ReconciliationBackend.message),
        .messageDeleted(id: ReconciliationBackend.message.id, in: room),
        .reactionChanged(messageID: ReconciliationBackend.message.id, reactions: []),
        .membersResolved([peer]),
        .membersChanged(conversationID: room, members: [peer]),
        .gap(scope: .conversation(room), reason: "fixture"),
        .gap(scope: .everything, reason: "fixture"),
        .historyInvalidated,
        .conversationHistoryInvalidated([room]),
        .conversationRemoved(conversationID: room, historyBefore: nil),
        .conversationsChanged([])
    ])
    func relevantFactsRetireTheResult(_ event: ChatEvent) {
        var read = PendingPinRead(conversation: Self.room, baseline: Self.row)
        read.observe(event)
        #expect(!read.accepts(Self.pins))
    }

    @Test func ordinaryArrivalsAndUnchangedDirectoryDoNotRetirePins() throws {
        var read = PendingPinRead(conversation: Self.room, baseline: Self.row)
        var arrival = ReconciliationBackend.message
        arrival.id = .init("ordinary-new-message")
        read.observe(.messageReceived(arrival))
        read.observe(.conversationsChanged([Self.row]))
        read.observe(.membersResolved([.init(id: .init("unrelated"), kind: .human)]))
        try read.observe(.historyLoaded(MessageHistoryUpdate(messages: [arrival], conversationID: Self.room)))
        #expect(read.accepts(Self.pins))
        arrival.activity = .pinnedMessage
        read.observe(.messageReceived(arrival))
        #expect(!read.accepts(Self.pins))
    }
}
