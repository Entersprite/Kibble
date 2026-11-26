import ChatKit
import Foundation
import Testing
@testable import ChatAPI

struct ConversationCallWireTests {
    @Test func groupControlAndParticipantStateRoundTripWithoutProviderReferences() throws {
        let source = UUID(), id = UUID()
        let request = ControlConversationCall(
            action: "join",
            conversationID: .init("group"),
            callID: id,
            sourceID: source
        )
        let data = try JSONEncoder().encode(request)
        #expect(try JSONDecoder().decode(ControlConversationCall.self, from: data).callID == id)
        let person = CallParticipantDevice(id: UUID(), displayName: "Test person")
        let call = ConversationCallSnapshot(
            id: id, target: .init(conversationID: .init("group"), displayName: "Group"), phase: .connected
        )
        let state = ServiceCallState(
            version: source.uuidString + ":1",
            supportsConversationCalls: true,
            conversationCall: call,
            participants: [person]
        )
        #expect(try JSONDecoder().decode(ServiceCallState.self, from: JSONEncoder().encode(state)) == state)
        let event = AudioCallEvent.participantsChanged(callID: id, participants: [person])
        #expect(try JSONDecoder().decode(AudioCallEvent.self, from: JSONEncoder().encode(event)) == event)
        let groupEvent = AudioCallEvent.conversationSnapshot(call)
        #expect(try JSONDecoder()
            .decode(AudioCallEvent.self, from: JSONEncoder().encode(groupEvent)) == groupEvent)
    }
}
