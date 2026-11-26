import ChatAPI
import ChatKit
import Foundation
import ServiceClient
import Testing
@testable import ChatService

/// The other person's microphone crosses the serialized call API unchanged,
/// and unknown stays unknown on the far side.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct CallRemoteMuteTests {
    @Test func remoteMicrophoneStateReachesTheClientThroughTheSerializedSnapshot() async throws {
        let harness = try await CallHarness.make()
        let account = harness.accounts[0]
        let recipient = try #require(try await harness.read(account).recipients.first)
        let source = try #require(await harness.providers.source(account.id, device: .init("one")))
        let id = try #require(source.receiveIncoming(from: recipient))
        try await callEventually { try await harness.read(account).call?.phase == .incoming }
        #expect(try await harness.read(account).call?.remoteMuted == nil)
        _ = try await harness.client().call(
            ControlCall(action: "accept", callID: id, sourceID: harness.read(account).sourceID),
            account: account.id, revision: account.currentRevision
        )
        source.setRemoteMuted(true, callID: id)
        try await callEventually { try await harness.read(account).call?.remoteMuted == true }
        source.setRemoteMuted(false, callID: id)
        try await callEventually { try await harness.read(account).call?.remoteMuted == false }
        source.setRemoteMuted(nil, callID: id)
        try await callEventually {
            let call = try await harness.read(account).call
            return call?.phase == .connected && call?.remoteMuted == nil
        }
        await harness.service.shutdown()
    }
}
