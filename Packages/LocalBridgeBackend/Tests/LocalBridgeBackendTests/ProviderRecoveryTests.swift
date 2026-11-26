import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

@Suite(.timeLimit(.minutes(1)))
struct ProviderRecoveryTests {
    @Test func paginatedRecoveryCommitsEditsAndDeletesBeforeAdvancingItsCursor() async throws {
        let transport = ProviderRecoveryTransport()
        await transport.configure(replies: [
            .initWith(.paginated, events: [ProviderRecoveryTransport.event(revision: 11)]),
            .initWith(.completed, events: [ProviderRecoveryTransport.event(revision: 12, deleted: true)])
        ])
        try await withBackend(transport) { backend, log in
            try await eventually { await backend.recoveryFinished() }
            #expect(await transport.froms == [10, 11])
            #expect(await backend.recoveredRevision("space/a") == 12)
            let batches = await log.batches
            let edits = batches.flatMap(\.events).compactMap { event -> ChatKit.Message? in
                if case let .messageUpdated(message) = event {
                    return message
                }
                return nil
            }
            #expect(edits.count == 2)
            #expect(edits.first?.text == "Edited")
            #expect(edits.last?.isDeleted == true)
            #expect(!batches.contains { $0.invalidatesHistory })
        }
    }

    @Test func anotherConversationRemainsLiveWhileRecoveryWaitsForAResponse() async throws {
        let transport = ProviderRecoveryTransport()
        await transport.configure(replies: [.initWith(.completed)], hold: true)
        try await withBackend(transport) { backend, log in
            try await eventually { await transport.held }
            try await backend.injectRecoveryEvent(ProviderRecoveryTransport.event(
                revision: 11,
                group: "b",
                text: "Live B"
            ))
            try await eventually { await log.containsText("Live B") }
            #expect(await backend.recoveredRevision("space/a") == 10)
            try await backend.injectRecoveryEvent(ProviderRecoveryTransport.event(
                revision: 13,
                text: "Live A"
            ))
            #expect(await log.containsText("Live A") == false)
            await transport.release()
            try await eventually {
                let finished = await backend.recoveryFinished()
                let observed = await log.containsText("Live A")
                return finished && observed
            }
            #expect(await backend.recoveredRevision("space/a") == 13)
        }
    }

    @Test func expiredRecoveryRevalidatesHistoryInsteadOfClaimingMissingEventsWereReplayed() async throws {
        let transport = ProviderRecoveryTransport()
        await transport.configure(replies: [.initWith(.abortedFromRevisionTooOld)])
        try await withBackend(transport) { backend, log in
            try await eventually { await backend.recoveryFinished() }
            let batches = await log.batches
            // Only the conversation whose catch-up expired loses confidence.
            #expect(batches.flatMap(\.events).contains(
                .conversationHistoryInvalidated([Conversation.ID("space/a")])
            ))
            #expect(!batches.contains { $0.invalidatesHistory })
            #expect(await backend.recoveredRevision("space/a") == 12)
        }
    }

    @Test func aConversationWithNoSavedPositionInvalidatesOnlyItsOwnHistory() async throws {
        let transport = ProviderRecoveryTransport()
        await transport.configure(replies: [.initWith(.completed)])
        var cursor = Self.cursor
        cursor.groups = ["space/a": 12]
        try await withBackend(transport, cursor: cursor) { backend, log in
            try await eventually { await backend.recoveryFinished() }
            let batches = await log.batches
            #expect(batches.flatMap(\.events).contains(
                .conversationHistoryInvalidated([Conversation.ID("space/b")])
            ))
            #expect(!batches.contains { $0.invalidatesHistory })
            #expect(await backend.recoveredRevision("space/b") == 10)
        }
    }

    /// Too many changed conversations to catch up one by one, from a known
    /// baseline: their history alone is unknown, not the whole account's.
    @Test func aRebaseFromABaselineInvalidatesOnlyTheChangedConversations() async throws {
        let transport = ProviderRecoveryTransport()
        let changed = (0 ..< 65).map { ("c\($0)", Int64(10)) }
        await transport.addGroups(changed)
        var cursor = Self.cursor
        for (id, _) in changed {
            cursor.groups["space/\(id)"] = 5
        }
        try await withBackend(transport, cursor: cursor) { backend, log in
            try await eventually { await backend.recoveryFinished() }
            let batches = await log.batches
            let expected = (changed.map { "space/\($0.0)" } + ["space/a"]).sorted()
                .map { Conversation.ID($0) }
            #expect(batches.flatMap(\.events).contains(.conversationHistoryInvalidated(expected)))
            #expect(!batches.contains { $0.invalidatesHistory })
        }
    }

    @Test(arguments: [false, true])
    func aRebaseWithoutABaselineOrPastTheBoundInvalidatesEverything(pastTheBound: Bool) async throws {
        let transport = ProviderRecoveryTransport()
        var cursor = Self.cursor
        if pastTheBound {
            let changed = (0 ..< LocalBridgeBackend.scopedInvalidationLimit).map { ("c\($0)", Int64(10)) }
            await transport.addGroups(changed)
        } else {
            cursor.baseline = false
        }
        try await withBackend(transport, cursor: cursor) { backend, log in
            try await eventually { await backend.recoveryFinished() }
            let batches = await log.batches
            #expect(batches.contains { $0.invalidatesHistory })
            #expect(!batches.flatMap(\.events).contains {
                if case .conversationHistoryInvalidated = $0 { true } else { false }
            })
        }
    }

    @Test func aReactionNotOnItsThreadPageInvalidatesOnlyItsConversation() async throws {
        let transport = ProviderRecoveryTransport()
        var reaction = Event()
        reaction.groupRevision.timestamp = 12
        reaction.type = .messageReacted
        var body = Event.EventBody()
        body.eventType = .messageReacted
        var target = ProviderRecoveryTransport.event(revision: 12).bodies[0].messagePosted.message.id
        target.messageID = "not-on-the-page"
        body.messageReaction.messageID = target
        reaction.bodies = [body]
        await transport.configure(replies: [.initWith(.completed, events: [reaction])])
        try await withBackend(transport) { backend, log in
            try await eventually { await backend.recoveryFinished() }
            let batches = await log.batches
            #expect(batches.flatMap(\.events).contains(
                .conversationHistoryInvalidated([Conversation.ID("space/a")])
            ))
            #expect(!batches.flatMap(\.events).contains(.historyInvalidated))
        }
    }

    @Test func aNonAdvancingPageStopsWithoutAdvancingOrFreezingLiveDelivery() async throws {
        let transport = ProviderRecoveryTransport()
        await transport.configure(replies: [.initWith(.paginated)])
        try await withBackend(transport) { backend, log in
            try await eventually { await backend.recoveryHasFailed() }
            #expect(await transport.froms == [10])
            #expect(await backend.recoveredRevision("space/a") == 10)
            try await backend.injectRecoveryEvent(ProviderRecoveryTransport.event(
                revision: 13,
                text: "Still live"
            ))
            try await eventually { await log.containsText("Still live") }
            #expect(await backend.recoveredRevision("space/a") == 10)
        }
    }

    @Test func shutdownRejectsALateNonCooperativeCatchUpResponse() async throws {
        let transport = ProviderRecoveryTransport()
        await transport.configure(
            replies: [.initWith(.completed, events: [ProviderRecoveryTransport.event(revision: 12)])],
            hold: true
        )
        try await withBackend(transport) { backend, log in
            try await eventually { await transport.held }
            let stopping = Task { await backend.disconnect() }
            try await eventually { await backend.hasStoppedDelivery() }
            let before = await log.batches.count
            await transport.release()
            await stopping.value
            #expect(await log.batches.count == before)
            #expect(await backend.recoveredRevision("space/a") == 10)
        }
    }

    @Test(arguments: [true, false])
    func unfamiliarResponsesNeverAdvanceTheCheckpoint(explicitStatus: Bool) async throws {
        let transport = ProviderRecoveryTransport()
        await transport.configure(replies: [explicitStatus ? .initWith(.unknown) : CatchUpResponse()])
        try await withBackend(transport) { backend, _ in
            try await eventually { await backend.recoveryHasFailed() }
            #expect(await backend.recoveredRevision("space/a") == 10)
        }
    }

    @Test func laterPostsCannotCheckpointPastAnUnfinishedReactionRead() async throws {
        let transport = ProviderRecoveryTransport()
        try await withBackend(transport) { backend, log in
            try await eventually { await backend.recoveryFinished() }
            await transport.holdReactionRead()
            var reaction = Event()
            reaction.groupRevision.timestamp = 13
            reaction.type = .messageReacted
            var body = Event.EventBody()
            body.eventType = .messageReacted
            body.messageReaction.messageID = ProviderRecoveryTransport.event(revision: 13).bodies[0]
                .messagePosted.message.id
            reaction.bodies = [body]
            try await backend.injectRecoveryEvent(reaction)
            try await eventually { await transport.messagesHeld }
            try await backend.injectRecoveryEvent(ProviderRecoveryTransport.event(
                revision: 14,
                text: "After reaction"
            ))
            try await eventually { await log.containsText("After reaction") }
            #expect(await backend.recoveredRevision("space/a") == 12)
            await transport.release()
            try await eventually { await backend.recoveredRevision("space/a") == 14 }
            let batches = await log.batches
            let index = try #require(batches.firstIndex { batch in
                batch.events.contains {
                    if case .reactionChanged = $0 {
                        true
                    } else {
                        false
                    }
                }
            })
            #expect(GoogleProviderCursor(data: batches[index].checkpoint).groups["space/a"] == 12)
            #expect(batches[(index + 1)...].contains {
                GoogleProviderCursor(data: $0.checkpoint).groups["space/a"] == 14
            })
        }
    }

    private static var cursor: GoogleProviderCursor {
        var cursor = GoogleProviderCursor()
        cursor.identity = "me"; cursor.baseline = true; cursor.user = 20
        cursor.groups = ["space/a": 10, "space/b": 10]
        return cursor
    }

    private func withBackend(
        _ transport: ProviderRecoveryTransport,
        cursor: GoogleProviderCursor = Self.cursor,
        run: (LocalBridgeBackend, RecoveryBatchLog) async throws -> Void
    ) async throws {
        let cookies = try #require(SessionCookies(header: "SID=fixture; COMPASS=fixture; OSID=fixture"))
        let backend = LocalBridgeBackend(
            cookies: cookies,
            transport: transport,
            retry: .immediate,
            reactionRefetchDelay: .zero
        )
        let log = RecoveryBatchLog()
        let consumer = Task {
            for await batch in backend.providerEventBatches {
                await log.append(batch)
                await backend.acknowledgeProviderBatch(batch.id)
            }
        }
        do {
            let source: any ProviderCheckpointBackend = backend
            try await source.connect(resumingProviderCheckpoint: cursor.encoded())
            try await run(backend, log)
            await transport.release(); await backend.disconnect()
            consumer.cancel(); _ = await consumer.result
        } catch {
            await transport.release(); await backend.disconnect()
            consumer.cancel(); _ = await consumer.result
            throw error
        }
    }

    private func eventually(_ condition: () async -> Bool) async throws {
        for _ in 0 ..< 500 {
            if await condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(await condition())
    }
}

private actor RecoveryBatchLog {
    private(set) var batches: [ProviderEventBatch] = []
    func append(_ batch: ProviderEventBatch) {
        batches.append(batch)
    }

    func containsText(_ text: String) -> Bool {
        batches.flatMap(\.events).contains {
            switch $0 {
            case let .messageReceived(message), let .messageUpdated(message): message.text == text
            default: false
            }
        }
    }
}

private extension LocalBridgeBackend {
    func recoveryFinished() -> Bool {
        isConnected && delivery.directory != nil && delivery.recovery == nil && !delivery.recoveryIncomplete
    }

    func hasStoppedDelivery() -> Bool {
        !delivery.running
    }

    func recoveryHasFailed() -> Bool {
        delivery.recovery == nil && delivery.recoveryIncomplete
    }

    func recoveredRevision(_ id: String) -> Int64? {
        delivery.cursor.groups[id]
    }

    func injectRecoveryEvent(_ event: Event) throws {
        try receiveCheckpointedEvent(ChannelEvent(protobuf: event))
    }
}

private extension CatchUpResponse {
    static func initWith(_ status: ResponseStatus, events: [Event] = []) -> Self {
        ProviderRecoveryTransport.page(status: status, events: events)
    }
}
