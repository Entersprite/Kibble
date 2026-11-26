import Foundation
import Testing
@testable import ChatKit

struct ConversionConsequencesCodingTests {
    private struct MinimalBackend: ChatBackend {
        var capabilities: Capabilities {
            Capabilities()
        }

        var events: AsyncStream<ChatEvent> {
            AsyncStream { $0.finish() }
        }

        func connect() async throws {}
        func disconnect() async {}
        func send(_: ChatCommand) async throws {}
        func loadConversations() async throws -> [Conversation] {
            []
        }

        func loadMessages(in _: Conversation.ID, before _: Message.ID?) async throws -> [Message] {
            []
        }

        func setNotificationSetting(_: NotificationLevel, for _: Conversation.ID) async throws {}
    }

    @Test func missingFieldsDecodeAsUnknownAndRequireAcknowledgement() throws {
        let value = try JSONDecoder().decode(ConversionConsequences.self, from: Data("{}".utf8))
        #expect(value.items.isEmpty)
        #expect(value.requiresHistoryAcknowledgement)
        let item = try JSONDecoder().decode(ConversionConsequence.self, from: Data("{}".utf8))
        #expect(item.topic == .unknown && item.outcome == .unknown)
    }

    @Test func unknownTopicsAndOutcomesRoundTrip() throws {
        let payload = Data(
            #"{"items":[{"topic":"future","outcome":"later"}],"requiresHistoryAcknowledgement":false}"#.utf8
        )
        let first = try JSONDecoder().decode(ConversionConsequences.self, from: payload)
        #expect(first.items.first?.topic.type == "future")
        #expect(first.items.first?.outcome.type == "later")
        #expect(!first.requiresHistoryAcknowledgement)
        let second = try JSONDecoder().decode(ConversionConsequences.self, from: JSONEncoder().encode(first))
        #expect(second == first)
    }

    @Test func tokenObjectsKeepTheirExtraFields() throws {
        let payload = Data(
            #"{"items":[{"topic":{"type":"future","extra":[1]},"outcome":{"type":"kept"}}]}"#.utf8
        )
        let first = try JSONDecoder().decode(ConversionConsequences.self, from: payload)
        #expect(first.items.first?.outcome == .kept)
        let second = try JSONDecoder().decode(ConversionConsequences.self, from: JSONEncoder().encode(first))
        #expect(second == first)
    }

    @Test func theDefaultRequirementIsUnsupported() async {
        await #expect(throws: ChatError.unsupported(capability: "conversionConsequences")) {
            let backend: any ChatBackend = MinimalBackend()
            _ = try await backend.conversionConsequences(Conversation.ID("space"))
        }
    }
}
