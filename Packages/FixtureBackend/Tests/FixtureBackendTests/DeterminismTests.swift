import ChatKit
import Foundation
import Testing
@testable import FixtureBackend

/// The property everything above the seam depends on: the same world plus the
/// same input produces the same frames, every run, forever.
///
/// Without it, a golden file recorded against this backend rots the moment the
/// suite runs a second later than it did before, and the failure looks like a
/// bug in whatever was being tested rather than in the fixture.
@Suite(.timeLimit(.minutes(1)))
struct DeterminismTests {
    private func encodedRun() async throws -> Data {
        let backend = FakeBackend(world: .minimal)
        let collector = EventCollector(backend.events)

        try await backend.connect()
        try await backend.send(
            .sendMessage(conversationID: .init("dm:1"), threadID: nil, text: "hi", localID: "d1")
        )
        try await backend.play(.smokeTest)

        // Asking the backend how much it emitted, rather than hardcoding a
        // count, keeps this test from hanging for a minute every time a step is
        // added to the smoke-test script.
        let events = await collector.next(backend.emittedCount)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(events)
    }

    /// Encoded rather than compared as values, deliberately: this checks the
    /// same coding path a bridge server would frame these through, so a
    /// timestamp that differs by a millisecond cannot hide behind `Equatable`.
    @Test func theSameWorldAndScriptProduceByteIdenticalFrames() async throws {
        let first = try await encodedRun()
        let second = try await encodedRun()
        #expect(first == second)
    }

    /// A second backend must not inherit the first one's counter or clock.
    @Test func twoBackendsBuiltFromOneWorldDoNotShareState() async throws {
        let world = FixtureWorld.minimal
        let left = FakeBackend(world: world)
        let right = FakeBackend(world: world)

        try await left.connect()
        try await left.send(
            .sendMessage(conversationID: .init("dm:1"), threadID: nil, text: "a", localID: nil)
        )

        #expect(await right.currentWorld == world)
        #expect(await left.currentWorld != world)
    }

    @Test func timestampsAdvanceByExactlyOneTickPerGeneratedThing() async throws {
        let backend = FakeBackend(world: .minimal, tick: .seconds(5))
        let collector = EventCollector(backend.events)
        try await backend.connect()
        _ = await collector.next(6)

        try await backend.send(
            .sendMessage(conversationID: .init("dm:1"), threadID: nil, text: "a", localID: nil)
        )
        try await backend.send(
            .sendMessage(conversationID: .init("dm:1"), threadID: nil, text: "b", localID: nil)
        )

        let events = await collector.next(4)
        let stamps = events.compactMap { event -> Date? in
            if case let .messageReceived(message) = event {
                return message.createdAt
            }
            return nil
        }
        try #require(stamps.count == 2)
        #expect(stamps[0] == FixtureWorld.minimal.startedAt.addingTimeInterval(5))
        #expect(stamps[1] == FixtureWorld.minimal.startedAt.addingTimeInterval(10))
    }

    /// Identifiers come from one counter shared across kinds, so nothing this
    /// backend mints can ever collide with anything else it minted.
    @Test func generatedIdentifiersAreSequentialAndUnique() async throws {
        let backend = FakeBackend(world: .minimal)
        let collector = EventCollector(backend.events)
        try await backend.connect()
        _ = await collector.next(6)

        for index in 1 ... 3 {
            try await backend.send(
                .sendMessage(
                    conversationID: .init("dm:1"),
                    threadID: nil,
                    text: "m\(index)",
                    localID: nil
                )
            )
        }

        let events = await collector.next(6)
        let ids = events.compactMap { event -> String? in
            if case let .messageReceived(message) = event {
                return message.id.rawValue
            }
            return nil
        }
        #expect(ids == ["fixture-msg-1", "fixture-msg-3", "fixture-msg-5"])
        #expect(Set(ids).count == ids.count)
    }

    /// The thread calls, a reply and the reply script, encoded twice. This
    /// catches a clock or a counter; it cannot catch a dictionary's order,
    /// whose hash seed is the same for both runs in one process, which is
    /// why the fixture never iterates `threadStates`.
    @Test func threadTrafficIsByteIdenticalToo() async throws {
        let first = try await encodedThreadRun()
        let second = try await encodedThreadRun()
        #expect(first == second)
    }

    private func encodedThreadRun() async throws -> Data {
        let backend = FakeBackend(world: .acme)
        let collector = EventCollector(backend.events)
        let sync = MessageThread.ID("topic:sync")
        let variance = MessageThread.ID("topic:variance")

        try await backend.connect()
        _ = try await backend.loadMessages(in: Acme.priceEngine, before: nil)
        _ = try await backend.loadThread(variance, in: Acme.priceEngine)
        try await backend.setThreadFollowed(true, thread: sync, in: Acme.priceEngine)
        try await backend.send(
            .sendMessage(conversationID: Acme.priceEngine, threadID: sync, text: "On it.", localID: "r-1")
        )
        try await backend.send(
            .markThreadRead(conversationID: Acme.priceEngine, threadID: variance, upTo: Acme.at(44))
        )
        try await backend.play(.acmeReplyArrives)
        _ = try await backend.loadFollowedThreads()

        let events = await collector.next(backend.emittedCount)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(events)
    }
}
