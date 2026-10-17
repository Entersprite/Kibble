import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

@MainActor
extension LocalBridgeAudioCallServiceTests {
    @Test func cancellingPreparePreventsMediaAndInvitation() async throws {
        let setup = try await setup(
            MeetDMCallTrialTests().preparingResponses(),
            hold: "ResolveForHangoutsChat"
        )
        try await setup.service.startListening()
        let id = UUID()
        let recipient = try recipient(setup)
        let starting = Task { try await setup.service.startOutgoing(to: recipient, callID: id) }
        try await waitForHold(setup)
        let scope = setup.service.callScope
        let ending = Task { try await setup.service.hangUp(callID: id) }
        for _ in 0 ..< 10000 {
            if setup.service.callScope != scope {
                break
            }
            await Task.yield()
        }
        await setup.transport.release()
        try await ending.value
        await #expect(throws: CancellationError.self) { try await starting.value }
        #expect(setup.media.engines.isEmpty)
        #expect(setup.service.snapshot?.phase == .ended)
        #expect(await setup.base.sent.allSatisfy { !$0.url.path.hasSuffix("CreateMeetingInvite") })
        await setup.service.stop()
    }

    @Test func stoppedRegistrationClosesImmediatelyThenSettlesOneLeave() async throws {
        let responses = [MeetDMCallTrialTests().preparingResponses()[0]]
            + NativeMeetFixture.responses(join: false)
        let setup = try await setup(responses, hold: "CreateMeetingDevice")
        try await setup.service.startListening()
        let id = UUID()
        let recipient = try recipient(setup)
        let starting = Task { try await setup.service.startOutgoing(to: recipient, callID: id) }
        try await waitForHold(setup)
        let stopping = Task { await setup.service.stop() }
        for _ in 0 ..< 10000 {
            if setup.media.engines.first?.closed == true {
                break
            }
            await Task.yield()
        }
        #expect(setup.media.engines.first?.closed == true)
        await setup.transport.release()
        await stopping.value
        await #expect(throws: CancellationError.self) { try await starting.value }
        #expect(setup.media.engines.first?.closeCount == 1)
        let updates = await setup.base.sent.filter { $0.url.path.hasSuffix("UpdateMeetingDevice") }
        #expect(updates.count == 1)
        #expect(await setup.base.sent.allSatisfy { !$0.url.path.hasSuffix("CreateMeetingInvite") })
        #expect(setup.service.snapshot == nil)
    }

    @Test func stoppedBootstrapCannotPublishRecipientsOrStartListenerAfterLateReply() async throws {
        let setup = try await setup(hold: "*")
        let starting = Task { try await setup.service.startListening() }
        try await waitForHold(setup)
        let stopping = Task { await setup.service.stop() }
        for _ in 0 ..< 10000 {
            if setup.service.isStopping {
                break
            }
            await Task.yield()
        }
        await setup.transport.release()
        await stopping.value
        await #expect(throws: CancellationError.self) { try await starting.value }
        #expect(setup.service.people.isEmpty)
        #expect(setup.service.incoming == nil)
        #expect(setup.media.engines.isEmpty)
        #expect(await setup.base.sent.count == 1)
    }

    @Test func failedInvitationTearsDownAudioBeforeReportingSafeFailure() async throws {
        var responses = nativeResponses(outgoing: true)
        responses[5] = .success(HTTPResponse(
            status: 500, headers: HTTPHeaders([]), body: Data("private-provider-text".utf8)
        ))
        responses.remove(at: 6) // No acknowledged invitation is available to cancel.
        let setup = try await setup(responses)
        try await setup.service.startListening()
        let recipient = try recipient(setup)
        await #expect(throws: ChatError.self) {
            try await setup.service.startOutgoing(to: recipient, callID: UUID())
        }
        #expect(setup.media.engines.first?.closed == true)
        #expect(setup.service.snapshot?.phase == .failed)
        #expect(setup.service.snapshot?.failureMessage?
            .hasPrefix("Call setup was refused (HTTP 500).") == true)
        #expect(setup.service.snapshot?.failureMessage?.contains("ringing was cancelled") == true)
        #expect(await setup.base.sent.filter { $0.url.path.hasSuffix("UpdateMeetingDevice") }.count == 2)
        #expect(await !(setup.service.report).contains("private-provider-text"))
        await setup.service.stop()
    }

    @Test func accountReplacementBeforeListeningRefusesTheNewAccountWithoutRequests() async throws {
        let setup = try await setup()
        let summary = try #require(try await setup.store.summary(at: Date()))
        let stored = try #require(try await setup.store.currentSession())
        try await setup.store.store(StoredSession(
            credential: stored.credential, capturedAt: stored.capturedAt.addingTimeInterval(1), expiresAt: nil
        ))
        let boundTrial = MeetDMCallTrial(
            store: setup.store, transport: setup.transport, expectedSession: summary
        )
        let service = LocalBridgeAudioCallService(trial: boundTrial, mediaFactory: { setup.media.make() })
        await #expect(throws: ChatError.self) { try await service.startListening() }
        #expect(await setup.base.sent.isEmpty)
        #expect(service.people.isEmpty)
        #expect(setup.media.engines.isEmpty)
        await service.stop()
    }

    @Test func staleMuteAndNativeStateCannotReachAReplacementCall() async throws {
        let setup = try await setup(nativeResponses(outgoing: true) + nativeResponses(outgoing: true))
        try await setup.service.startListening()
        let recipient = try recipient(setup)
        let oldID = UUID()
        try await setup.service.startOutgoing(to: recipient, callID: oldID)
        let scope = setup.service.callScope
        let engine = try #require(setup.media.engines.first)
        engine.holdMute = true
        let muting = Task { try await setup.service.setMuted(true, callID: oldID) }
        for _ in 0 ..< 10000 {
            if engine.pending != nil {
                break
            }
            await Task.yield()
        }
        try #require(engine.pending != nil)
        #expect(engine.isMicrophoneMuted)
        let ending = Task { try await setup.service.hangUp(callID: oldID) }
        for _ in 0 ..< 10000 {
            if engine.closed {
                break
            }
            await Task.yield()
        }
        try #require(engine.closed)
        engine.resume()
        try await ending.value
        await #expect(throws: CancellationError.self) { try await muting.value }
        let newID = UUID()
        try await setup.service.startOutgoing(to: recipient, callID: newID)
        let replacement = try #require(setup.media.engines.last)
        await #expect(throws: CancellationError.self) {
            try await setup.service.setMuted(true, callID: oldID)
        }
        setup.service.receiveNative(.active, id: oldID, scope: scope)
        #expect(setup.service.snapshot?.id == newID)
        #expect(setup.service.snapshot?.phase == .ringing)
        #expect(!replacement.isMicrophoneMuted)
        #expect(replacement.requests.count == 1)
        try await setup.service.hangUp(callID: newID)
        await setup.service.stop()
    }

    @Test func cancellingIncomingPreparationRetiresOfferAndCreatesNoMedia() async throws {
        let setup = try await setup(MeetDMCallTrialTests().preparingResponses(), hold: "ResolveMeetingSpace")
        try await setup.service.startListening()
        try await ring(setup)
        let id = try #require(setup.service.snapshot?.id)
        let starting = Task { try await setup.service.accept(callID: id) }
        try await waitForHold(setup)
        let scope = setup.service.callScope
        let ending = Task { try await setup.service.hangUp(callID: id) }
        for _ in 0 ..< 10000 {
            if setup.service.callScope != scope {
                break
            }
            await Task.yield()
        }
        await setup.transport.release()
        try await ending.value
        await #expect(throws: CancellationError.self) { try await starting.value }
        #expect(setup.media.engines.isEmpty)
        #expect(await setup.service.incoming?.offeredCall == nil)
        #expect(setup.service.snapshot?.phase == .ended)
        await setup.service.stop()
    }

    @Test func watchFailureAndActualSubscriptionReadinessCrossOnlyAsTypedDomainEvents() async throws {
        let setup = try await setup()
        var events = setup.service.events.makeAsyncIterator()
        try await setup.service.startListening()
        guard case .recipientsChanged = await events.next() else {
            Issue.record("Expected loaded recipients")
            return
        }
        let watcher = try #require(setup.service.incoming)
        for _ in 0 ..< 10000 {
            if await setup.transport.watched {
                break
            }
            await Task.yield()
        }
        await watcher.handle(.failed("private-provider-watch-sentinel"))
        #expect(await events.next() == .listenerChanged(isListening: false))
        await watcher.handle(.notification(.started))
        #expect(await events.next() == .listenerChanged(isListening: true))
        #expect(setup.media.engines.isEmpty)
        await setup.service.stop()
    }
}
