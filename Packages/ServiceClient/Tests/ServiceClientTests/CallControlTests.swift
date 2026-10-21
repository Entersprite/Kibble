import ChatAPI
import ChatKit
import Foundation
import ServiceClient
import Testing
@testable import ChatService

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct CallControlTests {
    @Test func membershipChangingWhileAdmissionIsHeldCannotDispatchAStaleInvitation() async throws {
        let harness = try await CallHarness.make(heldMembership: true)
        let account = harness.accounts[0]
        let recipient = try #require(try await harness.read(account).recipients.first)
        let gate = try #require(await harness.providers.gate(account.id))
        let runtime = try #require(await harness.service.runtimes[account.id])
        let command = Task {
            try await harness.client().call(
                ControlCall(
                    action: "start",
                    callID: UUID(),
                    recipient: recipient,
                    sourceID: harness.read(account, device: "one").sourceID
                ),
                account: account.id,
                revision: account.currentRevision
            )
        }
        do {
            try await callEventually { await gate.held }
            try await runtime.appendAndPublish(
                .membersChanged(
                    conversationID: recipient.conversationID,
                    members: [.init(
                        id: account.selfID,
                        kind: .human
                    )]
                ),
                live: true
            )
            await gate.release()
            await #expect(throws: ServiceFailure.overloaded) { try await command.value }
            let source = try #require(await harness.providers.source(account.id, device: .init("one")))
            #expect(source.currentCall == nil)
            await harness.service.shutdown()
        } catch {
            await gate.release()
            _ = await command.result
            await harness.service.shutdown()
            throw error
        }
    }

    @Test func anIncomingCallOnAnotherAccountRemainsPendingWhenAnsweringWouldTakeBusyMedia() async throws {
        let harness = try await CallHarness.make()
        let first = harness.accounts[0]; let second = harness.accounts[1]
        let recipient = try #require(try await harness.read(first).recipients.first)
        let id = UUID()
        _ = try await harness.client().call(
            ControlCall(
                action: "start",
                callID: id,
                recipient: recipient,
                sourceID: harness.read(first, device: "one").sourceID
            ),
            account: first.id,
            revision: first.currentRevision
        )
        let source = try #require(await harness.providers.source(second.id, device: .init("one")))
        let incoming = try #require(source.receiveIncoming(from: recipient))
        try await callEventually { try await harness.read(second).call?.phase == .incoming }
        await #expect(throws: ServiceFailure.deviceBusy) {
            try await harness.client().call(
                ControlCall(
                    action: "accept",
                    callID: incoming,
                    sourceID: harness.read(second, device: "one").sourceID
                ),
                account: second.id,
                revision: second.currentRevision
            )
        }
        #expect(source.currentCall?.phase == .incoming)
        #expect(try await harness.read(first).call?.id == id)
        _ = try await harness.client().call(
            ControlCall(
                action: "decline",
                callID: incoming,
                sourceID: harness.read(second, device: "one").sourceID
            ),
            account: second.id,
            revision: second.currentRevision
        )
        try await callEventually { try await harness.read(second).call?.phase == .declined }
        #expect(try await harness.read(first).call?.phase == .connected)
        await harness.service.shutdown()
    }

    @Test func cancelingOneLongPollReleasesOnlyItsWaiterAndAnotherStillReceivesTheCall() async throws {
        let harness = try await CallHarness.make()
        let account = harness.accounts[0]
        let runtime = try #require(await harness.service.runtimes[account.id])
        let calls = try #require(await runtime.calls[.init("one")])
        let initial = try await harness.read(account)
        let client = harness.client()
        let first = Task {
            try await client.call(
                ReadCallState(after: initial.version),
                account: account.id,
                revision: account.currentRevision
            )
        }
        let second = Task {
            try await client.call(
                ReadCallState(after: initial.version),
                account: account.id,
                revision: account.currentRevision
            )
        }
        try await callEventually { await calls.waitingReaderCount == 2 }
        first.cancel()
        _ = await first.result
        try await callEventually { await calls.waitingReaderCount == 1 }
        let source = try #require(await harness.providers.source(account.id, device: .init("one")))
        let recipient = try #require(initial.recipients.first)
        let id = try #require(source.receiveIncoming(from: recipient))
        #expect(try await second.value.call?.id == id)
        #expect(await calls.waitingReaderCount == 0)
        await harness.service.shutdown()
    }

    @Test func listenersAndCallsDoNotNeedChatReplicasAndBusyIsPerDeviceAcrossAccounts() async throws {
        let harness = try await CallHarness.make()
        let first = harness.accounts[0]; let second = harness.accounts[1]
        let recipient = try #require(try await harness.read(first).recipients.first)
        let id = UUID()
        let client = harness.client()
        _ = try await client.call(
            ControlCall(
                action: "start",
                callID: id,
                recipient: recipient,
                sourceID: harness.read(first, device: "one").sourceID
            ),
            account: first.id,
            revision: first.currentRevision
        )
        try await callEventually { try await harness.read(first).call?.phase == .connected }
        await #expect(throws: ServiceFailure.deviceBusy) {
            try await client.call(
                ControlCall(
                    action: "start",
                    callID: UUID(),
                    recipient: recipient,
                    sourceID: harness.read(second, device: "one").sourceID
                ),
                account: second.id,
                revision: second.currentRevision
            )
        }
        let otherID = UUID()
        _ = try await harness.client(device: "two").call(
            ControlCall(
                action: "start",
                callID: otherID,
                recipient: recipient,
                sourceID: harness.read(second, device: "two").sourceID
            ),
            account: second.id, revision: second.currentRevision
        )
        try await callEventually { try await harness.read(second, device: "two").call?.phase == .connected }
        let firstRuntime = try #require(await harness.service.runtimes[first.id])
        #expect(await firstRuntime.subscribers.isEmpty)
        _ = try await client.setEnabled(false, account: first.id)
        let source = try #require(await harness.providers.source(first.id, device: .init("one")))
        #expect(source.currentCall == nil)
        #expect(try await harness.read(second, device: "two").call?.id == otherID)
        await harness.service.shutdown()
    }

    @Test func nativeCallOwnershipCannotBeTakenByAnotherSessionOrDevice() async throws {
        let harness = try await CallHarness.make()
        let account = harness.accounts[0]
        let recipient = try #require(try await harness.read(account).recipients.first)
        let id = UUID()
        _ = try await harness.client().call(
            ControlCall(
                action: "start",
                callID: id,
                recipient: recipient,
                sourceID: harness.read(account, device: "one").sourceID
            ),
            account: account.id,
            revision: account.currentRevision
        )
        try await assertOtherOwnersRefused(harness, account: account, id: id)
        #expect(try await harness.read(account).call?.isMuted == false)
        _ = try await harness.client().call(
            ControlCall(
                action: "hangUp",
                callID: id,
                sourceID: harness.read(account, device: "one").sourceID
            ),
            account: account.id,
            revision: account.currentRevision
        )
        try await callEventually { try await harness.read(account).call?.phase == .ended }
        await #expect(throws: ServiceFailure.operationConflict) {
            try await harness.client().call(
                ControlCall(
                    action: "start",
                    callID: id,
                    recipient: recipient,
                    sourceID: harness.read(account, device: "one").sourceID
                ),
                account: account.id,
                revision: account.currentRevision
            )
        }
        await harness.service.shutdown()
    }

    @Test func apiFacadeDetachLeavesTheCallAliveAndReattachRestoresItsState() async throws {
        let harness = try await CallHarness.make()
        let client = harness.client()
        let summary = try #require(try await client.accounts().first)
        let facade = try ServiceAudioCallService(account: summary, client: client)
        try await facade.startListening()
        let account = try #require(harness.accounts.first { $0.id == summary.id })
        let verified = try #require(try await harness.read(account).recipients.first)
        let spoof = AudioCallRecipient(
            conversationID: verified.conversationID,
            memberID: verified.memberID,
            displayName: "Untrusted client label"
        )
        let id = UUID()
        try await facade.startOutgoing(to: spoof, callID: id)
        try await callEventually { try await harness.read(account).call?.phase == .connected }
        await facade.stop()
        #expect(try await harness.read(account).call?.recipient == verified)
        try await facade.startListening()
        try await facade.setMuted(true, callID: id)
        try await callEventually { try await harness.read(account).call?.isMuted == true }
        let source = try #require(await harness.providers.source(account.id, device: .init("one")))
        source.remoteEnded(callID: id)
        try await callEventually { try await harness.read(account).call?.endReason == .remoteEnded }
        await facade.stop()
        await harness.service.shutdown()
    }

    @Test func forgedRecipientUnknownActionAndStaleRevisionRefuseBeforeNativeControl() async throws {
        let harness = try await CallHarness.make()
        let account = harness.accounts[0]
        let client = harness.client()
        let forged = AudioCallRecipient(
            conversationID: .init("same"),
            memberID: .init("outsider"),
            displayName: "Not a member"
        )
        // A stale provider directory cannot override fresh membership admission.
        let source = try #require(await harness.providers.source(account.id, device: .init("one")))
        await source.updateRecipients([forged])
        try await callEventually { try await harness.read(account).recipients == [forged] }
        await #expect(throws: ServiceFailure.notAuthorized) {
            try await client.call(
                ControlCall(
                    action: "start",
                    callID: UUID(),
                    recipient: forged,
                    sourceID: harness.read(account, device: "one").sourceID
                ),
                account: account.id,
                revision: account.currentRevision
            )
        }
        await #expect(throws: ServiceFailure.unsupportedOperation) {
            try await client.call(
                ControlCall(
                    action: "future",
                    sourceID: harness.read(account, device: "one").sourceID
                ),
                account: account.id,
                revision: account.currentRevision
            )
        }
        await #expect(throws: ServiceFailure.staleAccount) {
            try await client.call(ReadCallState(), account: account.id, revision: .init("old"))
        }
        #expect(try await harness.read(account).call == nil)
        #expect(source.currentCall == nil)
        await harness.service.shutdown()
    }
}

private extension CallControlTests {
    func assertOtherOwnersRefused(_ harness: CallHarness, account: AccountRecord, id: UUID) async throws {
        for (device, client) in [
            ("one", harness.client(session: "other")),
            ("two", harness.client(device: "two"))
        ] {
            await #expect(throws: ServiceFailure.notAuthorized) {
                try await client.call(
                    ControlCall(
                        action: "mute",
                        callID: id,
                        muted: true,
                        sourceID: harness.read(account, device: device).sourceID
                    ),
                    account: account.id,
                    revision: account.currentRevision
                )
            }
        }
    }
}
