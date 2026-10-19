import ChatKit
import Foundation
import Testing
@testable import DesignSystem

struct MessageDeliveryPresentationTests {
    @Test func unresolvedAndFutureStatesOfferOnlyAStatusCheck() throws {
        let future = MessageDeliveryStatus(rawValue: "future-state")
        let roundTrip = try JSONDecoder().decode(
            MessageDeliveryStatus.self,
            from: JSONEncoder().encode(future)
        )
        #expect(roundTrip == future)
        for status in [MessageDeliveryStatus.unconfirmed, future] {
            #expect(MessageDeliveryPresentation.label(status) == "Delivery unconfirmed")
            #expect(MessageDeliveryPresentation.offersCheck(status))
        }
        #expect(MessageDeliveryPresentation.offersCheck(.sending))
        for status in [MessageDeliveryStatus.sent, .failed] {
            #expect(!MessageDeliveryPresentation.offersCheck(status))
        }
    }

    @Test func deliveryUpdatesInvalidateOnlyTheirOwnRow() {
        let message = Message(
            id: Message.ID("message"),
            conversationID: Conversation.ID("conversation"),
            threadID: MessageThread.ID("thread"),
            sender: Member.ID("self"),
            text: "Message",
            createdAt: Date()
        )
        var state = ChatSceneState(me: message.sender, messages: [message])
        let original = MessageRowState(message: message, scene: state)
        state.messageDeliveryStatuses[Message.ID("other")] = .unconfirmed
        #expect(MessageRowState(message: message, scene: state) == original)
        state.messageDeliveryStatuses[message.id] = .unconfirmed
        let pending = MessageRowState(message: message, scene: state)
        #expect(pending != original)
        #expect(pending.deliveryStatus == .unconfirmed)
        state.checkingMessageDeliveries.insert(message.id)
        #expect(MessageRowState(message: message, scene: state).checkingDelivery)
        // The delivery observation may retire its entry before the transcript
        // replaces the local row with the canonical echo.
        state.messageDeliveryStatuses[message.id] = nil
        state.pendingMessages.insert(message.id)
        #expect(!MessageRowState(message: message, scene: state).canUseProviderActions)
    }
}
