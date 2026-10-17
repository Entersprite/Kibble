import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct AudioCallDirectoryTests {
    @Test func newDMIsCallableAndReceivableWithoutReloadingOrRestartingTheWatch() async throws {
        let helper = LocalBridgeAudioCallServiceTests()
        let setup = try await helper.setup(helper.nativeResponses(outgoing: true))
        try await setup.service.startListening()
        let original = try helper.recipient(setup)
        let watcher = try #require(setup.service.incoming)
        let updated = AudioCallRecipient(
            conversationID: .init("dm/new-dm"), memberID: .init("new-peer"), displayName: "New Person"
        )
        let before = await setup.base.sent.count
        await setup.service.updateRecipients([original, updated])
        #expect(setup.service.incoming === watcher)
        #expect(await setup.base.sent.count == before)
        let firstID = try #require(setup.service.people.values.first { $0.memberID == updated.memberID }?.id)
        await setup.service.updateRecipients([updated])
        #expect(setup.service.people[firstID]?.name == "New Person")
        try await helper.ring(setup, dmID: "new-dm")
        #expect(setup.service.snapshot?.recipient == updated)
        #expect(setup.service.snapshot?.phase == .incoming)
        await setup.service.updateRecipients([])
        #expect(setup.service.snapshot?.phase == .ended)
        #expect(setup.media.engines.isEmpty)
        await setup.service.updateRecipients([updated])
        let id = UUID()
        try await setup.service.startOutgoing(to: updated, callID: id)
        let engine = try #require(setup.media.engines.first)
        await setup.service.updateRecipients([])
        #expect(setup.service.snapshot?.id == id)
        #expect(setup.service.snapshot?.phase == .ringing)
        #expect(!engine.closed)
        try await setup.service.hangUp(callID: id)
        await setup.service.stop()
    }

    @Test func directoryHintBeforeBootstrapIsAppliedAndForeignProviderIDsAreRefused() async throws {
        let helper = LocalBridgeAudioCallServiceTests()
        let setup = try await helper.setup()
        let recipient = AudioCallRecipient(
            conversationID: .init("dm/new-dm"), memberID: .init("new-peer"), displayName: "New Person"
        )
        await setup.service.updateRecipients([recipient, .init(
            conversationID: .init("fixture:dm"), memberID: .init("other"), displayName: "Other"
        )])
        try await setup.service.startListening()
        #expect(setup.service.people.values.map(LocalBridgeAudioCallService.recipient) == [recipient])
        await setup.service.stop()
        #expect(setup.service.people.isEmpty)
    }
}
