import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// Presence for people met after the world load: senders in a space, whose
/// names are looked up on demand and whose faces sit beside their messages.
@Suite(.timeLimit(.minutes(1)))
struct PresenceSenderTests: PresencePollFixtures {
    /// A sender looked up while a poll is running is asked about at once, on
    /// their own, after their name has been emitted. Making the lookup's add
    /// wait for the next interval turns this red.
    @Test func aSenderMetLaterIsAskedAboutAtOnce() async throws {
        let transport = try transport(
            [.people(["u-1": .active]), .people(["u-2": .inactive])],
            dmMembers: ["u-1"],
            topics: topics(from: ["u-2"])
        )
        let backend = backend(transport)
        let log = SenderEventLog(backend)
        try await backend.connect()
        _ = try await backend.loadConversations()
        try await awaitPolls(1, on: transport)

        _ = try await backend.loadMessages(in: Self.space, before: nil)
        try await awaitPolls(2, on: transport)
        let events = await log.settle()

        let oneOff = try #require(await transport.polls.last)
        #expect(oneOff.userIds.map(\.id) == ["u-2"])
        #expect(presences(in: events)[grace] == [.inactive])
        let named = try #require(events.firstIndex {
            if case .membersResolved = $0 {
                return true
            }
            return false
        })
        let dot = try #require(events
            .firstIndex { $0 == .presenceChanged(member: grace, presence: .inactive) })
        #expect(named < dot)
        await backend.disconnect()
    }

    /// The loop reads who to ask on every run, so a later run carries the
    /// senders met since. Capturing the set once, at start, turns this red.
    @Test func laterRunsAskAboutEveryoneMetSoFar() async throws {
        let transport = try transport(
            [.people(["u-1": .active, "u-2": .active])],
            dmMembers: ["u-1"],
            topics: topics(from: ["u-2"])
        )
        let backend = backend(transport, interval: .milliseconds(20))
        let log = SenderEventLog(backend)
        try await backend.connect()
        _ = try await backend.loadConversations()
        try await awaitPolls(1, on: transport)

        _ = try await backend.loadMessages(in: Self.space, before: nil)
        let before = await transport.polls.count
        try await awaitPolls(before + 3, on: transport)
        _ = await log.settle()

        let last = try #require(await transport.polls.last)
        #expect(Set(last.userIds.map(\.id)) == ["u-1", "u-2"])
        await backend.disconnect()
    }

    /// The one-off poll is never cancelled, so its session check is the
    /// directory generation. An answer that lands after `disconnect()` emits
    /// nothing. Deleting the generation check after the call turns this red.
    @Test func aOneOffThatLandsAfterDisconnectEmitsNothing() async throws {
        let transport = try transport(
            [.people(["u-1": .active]), .people(["u-2": .active])],
            dmMembers: ["u-1"],
            topics: topics(from: ["u-2"]),
            holdPollAt: 1
        )
        let backend = backend(transport)
        let log = SenderEventLog(backend)
        try await backend.connect()
        _ = try await backend.loadConversations()
        try await awaitPolls(1, on: transport)
        _ = try await backend.loadMessages(in: Self.space, before: nil)
        // Positive control: the one-off is out, and held.
        try await awaitPolls(2, on: transport)

        await backend.disconnect()
        await transport.release()
        try await awaitAnswered(2, on: transport)
        let events = await log.settle()

        #expect(presences(in: events)[grace] == nil)
    }

    // MARK: - People the client has on screen

    /// Someone in a stored transcript whose name is already known is never
    /// looked up this session, so only the client can name them. A watch
    /// asks about them at once. Making the watch wait for the next interval
    /// turns this red.
    @Test func aWatchedPersonIsAskedAboutAtOnce() async throws {
        let transport = try transport(
            [.people(["u-1": .active]), .people(["u-3": .inactive])], dmMembers: ["u-1"]
        )
        let backend = backend(transport)
        let log = SenderEventLog(backend)
        try await backend.connect()
        _ = try await backend.loadConversations()
        try await awaitPolls(1, on: transport)

        try await backend.send(.watchPresence(members: [ChatKit.Member.ID("u-3")]))
        try await awaitPolls(2, on: transport)
        let events = await log.settle()

        #expect(await transport.polls.last?.userIds.map(\.id) == ["u-3"])
        #expect(presences(in: events)[ChatKit.Member.ID("u-3")] == [.inactive])
        await backend.disconnect()
    }

    /// A watch that arrives between sessions is dropped, rather than seeding
    /// the next session's poll - which, after a sign-out, is another
    /// account's. Deleting the `apiClient` guard turns this red.
    @Test func aWatchBetweenSessionsIsDropped() async throws {
        let transport = try transport([.people(["u-1": .active])], dmMembers: ["u-1"])
        let backend = backend(transport)
        let log = SenderEventLog(backend)
        try await backend.connect()
        _ = try await backend.loadConversations()
        try await awaitPolls(1, on: transport)
        await backend.disconnect()

        try await backend.send(.watchPresence(members: [ChatKit.Member.ID("u-3")]))
        try await backend.connect()
        _ = try await backend.loadConversations()
        try await awaitPolls(2, on: transport)
        _ = await log.settle()

        let polls = await transport.polls
        #expect(polls.count == 2)
        #expect(!polls.flatMap(\.userIds).map(\.id).contains("u-3"))
        await backend.disconnect()
    }
}
