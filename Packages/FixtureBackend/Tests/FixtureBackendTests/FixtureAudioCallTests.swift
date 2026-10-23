import ChatKit
import Foundation
import Testing
@testable import FixtureBackend

@MainActor
struct FixtureAudioCallTests {
    @Test func availabilityOnlyIncludesHumanOneToOneConversations() throws {
        let service = FixtureAudioCallService()
        let world = FixtureWorld.acme
        #expect(!service.recipients.isEmpty)
        for recipient in service.recipients {
            let conversation = try #require(world.conversation(recipient.conversationID))
            #expect(conversation.kind == .directMessage)
            #expect(Set(conversation.members) == Set([world.me, recipient.memberID]))
            #expect(world.member(recipient.memberID)?.kind == .human)
        }
    }

    @Test func incomingAcceptMuteEndAndRepeatAreDeterministic() async throws {
        let first = FixtureAudioCallService(world: .minimal)
        let second = FixtureAudioCallService(world: .minimal)
        try await first.startListening()
        try await second.startListening()
        let recipient = try #require(first.recipients.first)
        let id = try #require(first.receiveIncoming(from: recipient))
        #expect(second.receiveIncoming(from: recipient) == id)
        #expect(first.currentCall?.phase == .incoming)
        #expect(first.receiveIncoming(from: recipient) == nil)
        try await first.accept(callID: id)
        #expect(first.currentCall?.phase == .connected)
        try await first.setMuted(true, callID: id)
        #expect(first.currentCall?.isMuted == true)
        try await first.setMuted(false, callID: id)
        #expect(first.currentCall?.isMuted == false)
        first.remoteEnded(callID: id)
        #expect(first.currentCall?.phase == .ended)
        let repeatID = try #require(first.receiveIncoming(from: recipient))
        #expect(repeatID != id)
        try await first.decline(callID: repeatID)
        #expect(first.currentCall?.phase == .declined)
        await first.stop()
        #expect(first.currentCall == nil)
        #expect(first.receiveIncoming(from: recipient) == nil)
    }

    @Test func remoteMicrophoneCanBeScriptedAndSurvivesOwnMuteAndPhaseChanges() async throws {
        let service = FixtureAudioCallService(world: .minimal)
        try await service.startListening()
        let recipient = try #require(service.recipients.first)
        let id = try #require(service.receiveIncoming(from: recipient))
        #expect(service.currentCall?.remoteMuted == nil)
        try await service.accept(callID: id)
        service.setRemoteMuted(true, callID: id)
        #expect(service.currentCall?.remoteMuted == true)
        try await service.setMuted(true, callID: id)
        #expect(service.currentCall?.remoteMuted == true)
        service.setRemoteMuted(false, callID: id)
        #expect(service.currentCall?.remoteMuted == false)
        service.setRemoteMuted(nil, callID: id)
        #expect(service.currentCall?.remoteMuted == nil)
        // Negative control: another call's hook and a finished call change nothing.
        service.setRemoteMuted(true, callID: UUID())
        #expect(service.currentCall?.remoteMuted == nil)
        try await service.hangUp(callID: id)
        service.setRemoteMuted(true, callID: id)
        #expect(service.currentCall?.remoteMuted == nil)
    }

    @Test func outgoingEventsCarryCallScopeAndStaleActionsCannotChangeReplacement() async throws {
        let service = FixtureAudioCallService(world: .minimal)
        try await service.startListening()
        var iterator = service.events.makeAsyncIterator()
        #expect(await iterator.next() == .recipientsChanged(service.recipients))
        #expect(await iterator.next() == .listenerChanged(isListening: true))
        let recipient = try #require(service.recipients.first)
        let id = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000077"))
        try await service.startOutgoing(to: recipient, callID: id)
        let ringing = AudioCallSnapshot(id: id, recipient: recipient, direction: .outgoing, phase: .ringing)
        #expect(await iterator.next() == .snapshot(ringing))
        var connected = ringing
        connected.phase = .connected
        #expect(await iterator.next() == .snapshot(connected))
        try await service.hangUp(callID: id)
        let next = try #require(service.receiveIncoming(from: recipient))
        try await service.hangUp(callID: id)
        try await service.setMuted(true, callID: id)
        #expect(service.currentCall?.id == next)
        #expect(service.currentCall?.phase == .incoming)
        #expect(service.currentCall?.isMuted == false)
    }
}
