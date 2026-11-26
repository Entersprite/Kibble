import ChatKit
import Foundation
import Testing
@testable import ChatPersistence
@testable import SyncEngine

struct MessageDeliveryStoreTests {
    private let conversation = Conversation.ID("conversation")

    @Test func terminalConfirmationCannotBeDowngradedByAnOlderStatusReply() throws {
        let store = try ChatStore.inMemory()
        let id = Message.ID("local/original")
        try store.apply([.upsertMessage(message(id, localID: "original")), .beginMessageDelivery(id)])
        try store.apply([.setMessageDelivery(id, .sent), .setMessageDelivery(id, .unconfirmed)])
        #expect(try store.messageDeliveries().first?.status == .sent)
    }

    @Test func pendingDeliveryPersistsAndInterruptedStateRequiresConfirmation() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".sqlite")
        try persistPending(file)
        let reopened = try ChatStore.onDisk(at: file.path)
        #expect(try reopened.messageDeliveries().first?.status == .sending)
        try reopened.apply([.clearEphemeralState, .interruptMessageDeliveries])
        let pending = try #require(try reopened.messageDeliveries().first)
        #expect(pending.status == .unconfirmed)
        #expect(pending.localID == "original")
        #expect(try reopened.message(pending.messageID)?.text == "A pending message")
    }

    @Test func echoAndEraseRemoveTrackingAndLateUpdatesNeverRecreateIt() throws {
        let store = try ChatStore.inMemory()
        let local = Message.ID("local/original")
        try store.apply([.upsertMessage(message(local, localID: "original")), .beginMessageDelivery(local)])
        try store.apply([.upsertMessage(message(Message.ID("canonical"), localID: "original"))])
        #expect(try store.messageDeliveries().isEmpty)
        try store.apply([.setMessageDelivery(local, .unconfirmed)])
        #expect(try store.messageDeliveries().isEmpty)
        #expect(try store.messages(in: conversation).map(\.id) == [Message.ID("canonical")])
        let other = Message.ID("local/other")
        try store.apply([.upsertMessage(message(other, localID: "other")), .beginMessageDelivery(other)])
        try store.erase()
        try store.apply([.setMessageDelivery(other, .sent)])
        #expect(try store.messageDeliveries().isEmpty)
        #expect(try store.messages(in: conversation).isEmpty)
    }

    @Test func pendingBudgetRefusesBeforeInsertionAndRecoversAfterAnEcho() throws {
        let store = try ChatStore.inMemory()
        let writes: [StoreWrite] = (0 ..< 512).flatMap { index -> [StoreWrite] in
            let id = Message.ID("local/\(index)")
            return [.upsertMessage(message(id, localID: String(index))), .beginMessageDelivery(id)]
        }
        try store.apply(writes)
        let extra = Message.ID("local/extra")
        #expect(throws: (any Error).self) {
            try store.apply([.upsertMessage(message(extra, localID: "extra")), .beginMessageDelivery(extra)])
        }
        #expect(try store.message(extra) == nil)
        #expect(try store.messageDeliveries().count == 512)
        try store.apply([.upsertMessage(message(Message.ID("canonical"), localID: "0"))])
        try store.apply([.upsertMessage(message(extra, localID: "extra")), .beginMessageDelivery(extra)])
        #expect(try store.messageDeliveries().count == 512)
    }

    private func persistPending(_ file: URL) throws {
        let store = try ChatStore.onDisk(at: file.path)
        let id = Message.ID("local/original")
        try store.apply([.upsertMessage(message(id, localID: "original")), .beginMessageDelivery(id)])
    }

    private func message(_ id: Message.ID, localID: String) -> Message {
        Message(
            id: id,
            conversationID: conversation,
            threadID: MessageThread.ID("thread"),
            sender: Member.ID("self"),
            text: "A pending message",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            localID: localID
        )
    }
}
