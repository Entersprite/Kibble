import ChatAPI
import ChatKit
import Foundation
import Testing
@testable import ChatService

extension ReconciliationBackend {
    func setPinQuery(_ query: (@Sendable () async throws -> PinnedMessages)?) {
        pinQuery = query
    }

    func pinnedMessages(in _: Conversation.ID) async throws -> PinnedMessages {
        try await pinQuery?() ?? PinnedMessages()
    }
}

private actor PinQueryCount {
    var reads = 0
    func next() -> Int {
        reads += 1; return reads
    }
}

@Suite(.timeLimit(.minutes(1)))
struct MessagePinQueryTests {
    @Test func concurrentMediaQueriesCannotExhaustAPinRefresh() async throws {
        let harness = try await ReconciliationHarness.make(pins: true)
        let runtime = try #require(await harness.service.runtimes[harness.record.id])
        try await authEventually { await runtime.worldRefresh == nil }
        let count = PinQueryCount()
        await harness.backend.setPinQuery {
            _ = await count.next()
            _ = try await harness.call(SearchPeople(query: "profile"))
            return PinnedMessages(messages: [ReconciliationBackend.message], canModify: true)
        }
        do {
            let pins = try await harness
                .call(GetMessagePins(conversationID: ReconciliationBackend.conversation))
            #expect(pins.messages.map(\.id) == [ReconciliationBackend.message.id])
            #expect(await count.reads == 1)
        } catch {
            await harness.backend.setPinQuery(nil)
            await harness.service.shutdown()
            throw error
        }
        await harness.backend.setPinQuery(nil)
        await harness.service.shutdown()
    }

    @Test func initialHistoryReconciliationCannotStarveThePinCollection() async throws {
        let harness = try await ReconciliationHarness.make(pins: true)
        let runtime = try #require(await harness.service.runtimes[harness.record.id])
        try await authEventually { await runtime.worldRefresh == nil }
        let count = PinQueryCount()
        await harness.backend.setPinQuery {
            _ = await count.next()
            _ = try await harness.call(LoadMessages(conversationID: ReconciliationBackend.conversation))
            return PinnedMessages(messages: [ReconciliationBackend.message])
        }
        do {
            let pins = try await harness
                .call(GetMessagePins(conversationID: ReconciliationBackend.conversation))
            #expect(pins.messages.map(\.id) == [ReconciliationBackend.message.id])
            #expect(await count.reads == 1)
        } catch {
            await harness.backend.setPinQuery(nil)
            await harness.service.shutdown()
            throw error
        }
        await harness.backend.setPinQuery(nil)
        await harness.service.shutdown()
    }

    @Test func unrelatedConversationTrafficAndProfilesCannotExhaustPinReads() async throws {
        let harness = try await ReconciliationHarness.make(pins: true)
        let runtime = try #require(await harness.service.runtimes[harness.record.id])
        try await authEventually { await runtime.worldRefresh == nil }
        let count = PinQueryCount()
        await harness.backend.setPinQuery {
            _ = await count.next()
            var message = ReconciliationBackend.message
            message.id = .init("other-message")
            message.conversationID = .init("other-conversation")
            await harness.backend.emit(.messageReceived(message))
            await harness.backend.emit(.membersResolved([.init(id: .init("unrelated-peer"), kind: .human)]))
            try await authEventually {
                await runtime.pinQueries.values
                    .contains { $0.changedMembers.contains(.init("unrelated-peer")) }
            }
            return PinnedMessages(messages: [ReconciliationBackend.message])
        }
        do {
            let value = try await harness
                .call(GetMessagePins(conversationID: ReconciliationBackend.conversation))
            #expect(value.messages.map(\.id) == [ReconciliationBackend.message.id])
            #expect(await count.reads == 1)
        } catch {
            await harness.backend.setPinQuery(nil)
            await harness.service.shutdown()
            throw error
        }
        await harness.backend.setPinQuery(nil)
        await harness.service.shutdown()
    }

    @Test func confirmedPinReadsCommitOneDurableSnapshotBeforeReplying() async throws {
        let harness = try await ReconciliationHarness.make(pins: true)
        let runtime = try #require(await harness.service.runtimes[harness.record.id])
        try await authEventually { await runtime.worldRefresh == nil }
        await harness.backend.setPinQuery {
            PinnedMessages(messages: [ReconciliationBackend.message], canModify: true)
        }
        let pins = try await harness.call(GetMessagePins(conversationID: ReconciliationBackend.conversation))
        let cache = try #require(harness.storage as? any ServiceMessagePinStorage)
        let saved = try #require(try cache.cachedMessagePins(in: ReconciliationBackend.conversation))
        #expect(saved.messages == pins.messages && !saved.canModify)
        let position = try harness.storage.checkpoint()
        _ = try await harness.call(GetMessagePins(conversationID: ReconciliationBackend.conversation))
        #expect(try harness.storage.checkpoint() == position)
        let snapshot = try harness.storage.readEvents(
            after: nil,
            limit: 1,
            includingHistory: [ReconciliationBackend.conversation]
        )
        #expect(snapshot.snapshot?.contains(.messagePinsLoaded(
            conversationID: ReconciliationBackend.conversation, pins: saved
        )) == true)
        await harness.service.shutdown()
    }

    @Test func aReturnedProfileChangeRequiresFreshPinsBeforeIssuingItsPhoto() async throws {
        let harness = try await ReconciliationHarness.make(pins: true)
        let runtime = try #require(await harness.service.runtimes[harness.record.id])
        try await authEventually { await runtime.worldRefresh == nil }
        let count = PinQueryCount()
        let old = Member(
            id: .init("peer"),
            kind: .human,
            avatarURL: URL(string: "https://images.example/old.png")
        )
        let current = Member(
            id: old.id,
            kind: .human,
            avatarURL: URL(string: "https://images.example/current.png")
        )
        await harness.backend.setPinQuery {
            if await count.next() == 1 {
                await harness.backend.emit(.membersResolved([current]))
                try await authEventually {
                    await runtime.pinQueries.values.contains { $0.changedMembers.contains(current.id) }
                }
                return PinnedMessages(messages: [ReconciliationBackend.message], members: [old])
            }
            return PinnedMessages(messages: [ReconciliationBackend.message], members: [current])
        }
        let pins = try await harness.call(GetMessagePins(conversationID: ReconciliationBackend.conversation))
        #expect(pins.members == [current])
        #expect(await count.reads == 2)
        let catalog = try #require(harness.storage as? any ServiceMediaCatalog)
        #expect(try catalog.mediaSources(for: .remoteImage(#require(old.avatarURL)), at: Date()).isEmpty)
        #expect(try catalog.mediaSources(for: .remoteImage(#require(current.avatarURL)), at: Date())
            .count == 1)
        await harness.service.shutdown()
    }

    @Test func aPinEventDuringTheReadStillRequiresAFreshCollection() async throws {
        let harness = try await ReconciliationHarness.make(pins: true)
        let runtime = try #require(await harness.service.runtimes[harness.record.id])
        try await authEventually { await runtime.worldRefresh == nil }
        let count = PinQueryCount()
        await harness.backend.setPinQuery {
            if await count.next() == 1 {
                await harness.backend.emit(.messagePinsChanged(ReconciliationBackend.conversation))
                try await authEventually { await runtime.pinQueries.values.contains { $0.invalidated } }
                return PinnedMessages()
            }
            return PinnedMessages(messages: [ReconciliationBackend.message])
        }
        do {
            let pins = try await harness
                .call(GetMessagePins(conversationID: ReconciliationBackend.conversation))
            #expect(pins.messages.map(\.id) == [ReconciliationBackend.message.id])
            #expect(await count.reads == 2)
        } catch {
            await harness.backend.setPinQuery(nil)
            await harness.service.shutdown()
            throw error
        }
        await harness.backend.setPinQuery(nil)
        await harness.service.shutdown()
    }
}
