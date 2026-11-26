import ChatAPI
import ChatKit
import ChatService
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct OutgoingForwardOperationTests {
    @Test func forwardingUsesTheDurableLedgerAndRefusesAnUnknownSourceConversation() async throws {
        let harness = try await ServiceHarness.make(includeCardActions: true)
        _ = try await harness.call(
            LoadMessages(conversationID: .init("same-conversation")),
            account: harness.first.id
        )
        let original = Message(
            id: .init("card"),
            conversationID: .init("same-conversation"),
            threadID: .init("thread"),
            sender: harness.first.selfID,
            text: "Untrusted preview",
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let operation = ServiceOperationID("forward-operation")
        let command = ChatCommand.sendMessage(
            conversationID: original.conversationID,
            threadID: nil,
            text: "Comment",
            localID: operation.rawValue,
            content: MessageContent(forwardSource: MessageQuote(message: original))
        )
        let request = SendCommand(operationID: operation, command: command)
        let accepted = try await harness.call(request, account: harness.first.id)
        #expect(accepted.state == "succeeded")
        #expect(try await harness.call(request, account: harness.first.id) == accepted)
        var foreign = MessageQuote(message: original)
        foreign.conversation = .init("not-visible")
        await #expect(throws: ServiceFailure.notAuthorized) {
            _ = try await harness.call(
                SendCommand(operationID: .init("foreign-forward"), command: .sendMessage(
                    conversationID: original.conversationID, threadID: nil, text: "",
                    localID: "foreign-forward",
                    content: MessageContent(forwardSource: foreign)
                )),
                account: harness.first.id
            )
        }
        let page = try await harness.call(
            LoadMessages(conversationID: original.conversationID),
            account: harness.first.id
        )
        #expect(page.messages.filter { $0.localID == operation.rawValue }.count == 1)
        #expect(page.messages.first { $0.localID == operation.rawValue }?.content?.forwarded?.source
            .text == "Example app")
        await harness.service.shutdown()
    }
}
