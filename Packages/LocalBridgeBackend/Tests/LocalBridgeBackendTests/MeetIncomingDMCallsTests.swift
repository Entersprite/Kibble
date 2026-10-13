import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

struct MeetIncomingDMCallsTests {
    private let person = UUID()

    private actor Preparation {
        private(set) var attempts = 0
        private(set) var discarded = 0
        private var held = false
        private var continuation: CheckedContinuation<Void, Never>?
        func discard() {
            discarded += 1
        }

        func hold() {
            held = true
        }

        func run() async -> PreparedMeetDMCall {
            attempts += 1
            if held {
                await withCheckedContinuation { continuation = $0 }
            }
            return PreparedMeetDMCall(id: UUID(), url: URL(string: "https://meet.google.com/abc-defg-hij")!)
        }

        func release() {
            held = false; continuation?.resume(); continuation = nil
        }
    }

    private func receiver(
        _ preparation: Preparation = Preparation(),
        validate: @escaping @Sendable () async throws -> Void = {},
        decline: @escaping @Sendable (MeetPushWire.Ring) async throws -> Void = { _ in }
    ) throws -> (MeetIncomingDMCalls, ScriptedTransport) {
        let configuration = try #require(MeetPushConfiguration(
            key: "key-secret",
            project: "project-secret",
            topic: "topic-secret"
        ))
        let transport = ScriptedTransport([])
        let credentials = SessionCredentials(SessionCookies(cookies: [.init(
            name: "SID",
            value: "cookie-secret"
        )])!)
        let receiver = MeetIncomingDMCalls(
            requests: PunctualRequests(meet: configuration, endpoints: ChatEndpoints()),
            topic: .meetRings(configuration), client: PunctualClient(
                transport: transport,
                credentials: credentials
            ),
            people: ["known-dm": person], validate: validate,
            prepare: { _, _ in await preparation.run() }, decline: decline,
            discard: { _ in await preparation.discard() }
        )
        return (receiver, transport)
    }

    private func ring(_ id: String = "ring-secret", dm: String = "dm/known-dm") -> MeetPushWire.Ring {
        // Public initializers are deliberately absent; construct a synthetic provider notification.
        var data = bytes(1, Data(id.utf8)) + bytes(2, Data("abc-defg-hij".utf8))
        data += Data([0x20, 0x01]) + bytes(11, Data(dm.utf8)) + Data([0x60, 0x01])
        guard case let .ring(ring) = try? MeetPushWire.payload(bytes(1, data))
        else { fatalError("Bad fixture") }
        return ring
    }

    private func bytes(_ field: UInt8, _ data: Data) -> Data {
        Data([field << 3 | 2, UInt8(data.count)]) + data
    }

    @Test func ringsOnlyLoadedHumanDMsAndUsesTemporaryHandles() async throws {
        let (receiver, transport) = try receiver()
        await receiver.handle(.notification(.ring(ring(dm: "space/unknown"))))
        #expect(await receiver.offeredCall == nil)
        await receiver.handle(.notification(.ring(ring("valid-ring"))))
        #expect(await receiver.offeredCall?.person == person)
        #expect(await transport.sent.isEmpty)
        let report = await receiver.report
        #expect(!report.contains("valid-ring"))
        #expect(!report.contains("known-dm"))
        await receiver.stop()
    }

    @Test func duplicateRingAndOldEndCannotReplaceOrClearANewerCall() async throws {
        let (receiver, _) = try receiver()
        await receiver.handle(.notification(.ring(ring("first"))))
        let first = try #require(await receiver.offeredCall)
        await receiver.dismiss(first.id)
        await receiver.handle(.notification(.ring(ring("second"))))
        let second = try #require(await receiver.offeredCall)
        await receiver.handle(.notification(.ended(id: "first", reason: 3)))
        await receiver.handle(.notification(.ring(ring("second"))))
        #expect(await receiver.offeredCall == second)
        await receiver.stop()
    }

    @Test func endBeforeRingAndLocalTimeoutSuppressReplays() async throws {
        let (receiver, _) = try receiver()
        await receiver.handle(.notification(.ended(id: "ended", reason: nil)))
        await receiver.handle(.notification(.ring(ring("ended"))))
        #expect(await receiver.offeredCall == nil)
        await receiver.handle(.notification(.ring(ring("fresh"))))
        let offered = try #require(await receiver.offeredCall)
        await receiver.expire(offered.id)
        await receiver.handle(.notification(.ring(ring("fresh"))))
        #expect(await receiver.offeredCall == nil)
        await receiver.stop()
    }

    @Test func dismissalAndUnknownHandlesNeverPrepareOrSend() async throws {
        let preparation = Preparation()
        let (receiver, transport) = try receiver(preparation)
        await #expect(throws: MeetDMCallTrialError.callNotPrepared) { try await receiver.accept(UUID()) }
        await receiver.handle(.notification(.ring(ring())))
        let offered = try #require(await receiver.offeredCall)
        await receiver.dismiss(offered.id)
        await #expect(throws: MeetDMCallTrialError.callNotPrepared) { try await receiver.accept(offered.id) }
        #expect(await preparation.attempts == 0)
        #expect(await transport.sent.isEmpty)
        await receiver.stop()
    }

    private actor Declines {
        var attempts = 0
        func send() {
            attempts += 1
        }
    }

    @Test func explicitDeclineRetiresTheRingWithoutPreparingAndCannotBeRepeated() async throws {
        let preparation = Preparation()
        let declines = Declines()
        let (receiver, transport) = try receiver(preparation, decline: { _ in await declines.send() })
        await receiver.handle(.notification(.ring(ring())))
        let offered = try #require(await receiver.offeredCall)
        try await receiver.decline(offered.id)
        await #expect(throws: MeetDMCallTrialError.callNotPrepared) { try await receiver.decline(offered.id) }
        await receiver.handle(.notification(.ring(ring())))
        #expect(await receiver.offeredCall == nil)
        #expect(await preparation.attempts == 0)
        #expect(await declines.attempts == 1)
        #expect(await transport.sent.isEmpty)
        #expect(await receiver.report.contains("DeclineMeetingInvite: accepted"))
        await receiver.stop()
    }

    @Test func ambiguousDeclineIsNotRetriedAndChangedAccountCannotSend() async throws {
        let declines = Declines()
        let (receiver, _) = try receiver(decline: { _ in
            await declines.send()
            throw MeetDMCallTrialError.callChanged
        })
        await receiver.handle(.notification(.ring(ring())))
        let offered = try #require(await receiver.offeredCall)
        await #expect(throws: MeetDMCallTrialError.callChanged) { try await receiver.decline(offered.id) }
        await #expect(throws: MeetDMCallTrialError.callNotPrepared) { try await receiver.decline(offered.id) }
        #expect(await declines.attempts == 1)
        #expect(await receiver.report.contains("DeclineMeetingInvite: unconfirmed"))
        await receiver.stop()
        let (changed, _) = try self.receiver(
            validate: { throw MeetDMCallTrialError.accountChanged },
            decline: { _ in await declines.send() }
        )
        await changed.handle(.notification(.ring(ring())))
        let changedCall = try #require(await changed.offeredCall)
        await #expect(throws: MeetDMCallTrialError.accountChanged) {
            try await changed.decline(changedCall.id)
        }
        #expect(await declines.attempts == 1)
        await changed.stop()
    }

    @Test func ownerAcceptPreparesExactlyOnceAndRetiresTheRing() async throws {
        let preparation = Preparation()
        let (receiver, transport) = try receiver(preparation)
        await receiver.handle(.notification(.ring(ring())))
        let offered = try #require(await receiver.offeredCall)
        _ = try await receiver.accept(offered.id)
        await #expect(throws: MeetDMCallTrialError.callNotPrepared) { try await receiver.accept(offered.id) }
        await receiver.handle(.notification(.ring(ring())))
        #expect(await receiver.offeredCall == nil)
        #expect(await preparation.attempts == 1)
        #expect(await transport.sent.isEmpty)
        await receiver.stop()
    }

    @Test func changedAccountPreventsPreparation() async throws {
        let preparation = Preparation()
        let (receiver, _) = try receiver(
            preparation,
            validate: { throw MeetDMCallTrialError.accountChanged }
        )
        await receiver.handle(.notification(.ring(ring())))
        let offered = try #require(await receiver.offeredCall)
        await #expect(throws: MeetDMCallTrialError.accountChanged) { try await receiver.accept(offered.id)
        }
        #expect(await preparation.attempts == 0)
        await receiver.stop()
    }

    @Test func callerEndDuringResolvePreventsAcceptance() async throws {
        let preparation = Preparation()
        await preparation.hold()
        let (receiver, _) = try receiver(preparation)
        await receiver.handle(.notification(.ring(ring())))
        let offered = try #require(await receiver.offeredCall)
        let task = Task { try await receiver.accept(offered.id) }
        while await preparation.attempts == 0 {
            await Task.yield()
        }
        await receiver.handle(.notification(.ended(id: "ring-secret", reason: 2)))
        await preparation.release()
        await #expect(throws: MeetDMCallTrialError.superseded) { try await task.value }
        #expect(await preparation.discarded == 1)
        await receiver.stop()
    }

    @Test func stopDuringResolveAndOldWatcherDeliveryAreIgnored() async throws {
        let preparation = Preparation()
        await preparation.hold()
        let (receiver, _) = try receiver(preparation)
        await receiver.handle(.notification(.ring(ring())))
        let offered = try #require(await receiver.offeredCall)
        let task = Task { try await receiver.accept(offered.id) }
        while await preparation.attempts == 0 {
            await Task.yield()
        }
        await receiver.stop()
        await preparation.release()
        await #expect(throws: MeetDMCallTrialError.superseded) { try await task.value }
        #expect(await preparation.discarded == 1)
        await receiver.handle(.notification(.ring(ring("late"))), scope: UUID())
        #expect(await receiver.offeredCall == nil)
    }
}
