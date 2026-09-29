import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// The `get_user_presence` poll: who is asked, when, and what reaches the
/// event stream.
@Suite(.timeLimit(.minutes(1)))
struct PresencePollTests: SenderResolutionFixtures {
    private let ada = ChatKit.Member.ID("u-1")
    private let grace = ChatKit.Member.ID("u-2")

    private func backend(
        _ transport: PresenceTransport,
        interval: Duration = .seconds(3600)
    ) -> LocalBridgeBackend {
        LocalBridgeBackend(
            cookies: Self.cookies,
            transport: transport,
            retry: .default,
            presencePollInterval: interval
        )
    }

    private func transport(
        _ answers: [PresenceTransport.Answer],
        dmMembers: [String] = ["u-1", "u-2"],
        heldPolls: Int = 0
    ) throws -> PresenceTransport {
        try PresenceTransport(
            shell: shell(), world: world(dmMembers: dmMembers), answers: answers, heldPolls: heldPolls
        )
    }

    /// Until `transport` has seen `count` polls. Bounded, for the reason
    /// `awaitLookups` is.
    private func awaitPolls(_ count: Int, on transport: PresenceTransport) async throws {
        for _ in 0 ..< 400 where await transport.polls.count < count {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(await transport.polls.count >= count)
    }

    private func presences(in events: [ChatEvent]) -> [ChatKit.Member.ID: [ChatKit.Presence]] {
        var result: [ChatKit.Member.ID: [ChatKit.Presence]] = [:]
        for case let .presenceChanged(member, presence) in events {
            result[member, default: []].append(presence)
        }
        return result
    }

    private func pollErrors(in events: [ChatEvent]) -> Int {
        events.count {
            if case let .backendError(error) = $0 {
                return "\(error)".contains("get_user_presence")
            }
            return false
        }
    }

    // MARK: - Who, and when

    @Test func theWorldLoadAsksAboutEveryDMPartnerAtOnce() async throws {
        let transport = try transport([.people(["u-1": .active, "u-2": .inactive])])
        let backend = backend(transport)
        let log = SenderEventLog(backend)
        try await backend.connect()

        _ = try await backend.loadConversations()
        try await awaitPolls(1, on: transport)
        let events = await log.settle()

        let poll = try #require(await transport.polls.first)
        #expect(Set(poll.userIds.map(\.id)) == ["u-1", "u-2"])
        #expect(poll.includeUserStatus)
        #expect(presences(in: events) == [ada: [.active], grace: [.inactive]])
        await backend.disconnect()
    }

    /// Only a one-to-one DM's members are asked about.
    @Test func onlyDirectMessagePartnersAreTargets() {
        let conversations = [
            Conversation(id: Conversation.ID("dm/1"), kind: .directMessage, members: [ada]),
            Conversation(id: Conversation.ID("dm/2"), kind: .groupDirectMessage, members: [grace]),
            Conversation(
                id: Conversation.ID("dm/3"),
                kind: .appDirectMessage,
                members: [ChatKit.Member.ID("bot")]
            ),
            Conversation(id: Conversation.ID("space/1"), kind: .space, members: [ChatKit.Member.ID("u-3")])
        ]
        #expect(LocalBridgeBackend.presenceTargets(in: conversations) == [ada])
    }

    @Test func aWorldWithNoDMsSendsNoPoll() async throws {
        var world = PaginatedWorldResponse()
        var item = WorldItemLite()
        item.groupID = spaceGroupID()
        world.worldItems = [item]
        let transport = try PresenceTransport(
            shell: shell(),
            world: HTTPResponse(status: 200, headers: HTTPHeaders([]), body: world.serializedBytes()),
            answers: [.people(["u-1": .active])]
        )
        let backend = backend(transport)
        let log = SenderEventLog(backend)
        try await backend.connect()

        _ = try await backend.loadConversations()
        _ = await log.settle()

        #expect(await transport.polls.isEmpty)
        await backend.disconnect()
    }

    // MARK: - What is emitted

    /// A poll that learns nothing new emits nothing, and a change emits once.
    @Test func onlyChangesAreEmitted() async throws {
        let transport = try transport([
            .people(["u-1": .active]),
            .people(["u-1": .active]),
            .people(["u-1": .inactive])
        ], dmMembers: ["u-1"])
        let backend = backend(transport, interval: .milliseconds(20))
        let log = SenderEventLog(backend)
        try await backend.connect()

        _ = try await backend.loadConversations()
        try await awaitPolls(4, on: transport)
        let events = await log.settle()

        #expect(presences(in: events)[ada] == [.active, .inactive])
        await backend.disconnect()
    }

    /// Someone answered for once and missing from a later answer stops being
    /// drawn as they were. Someone never answered for is left at "nobody told
    /// us" rather than given an invented state.
    @Test func aPersonMissingFromALaterAnswerIsNoLongerShownAsTheyWere() async throws {
        // The later answer names only Grace: an answer naming nobody is an
        // empty body, which `ProtoAPIClient` rejects for every call.
        let transport = try transport([.people(["u-1": .active]), .people(["u-2": .inactive])])
        let backend = backend(transport, interval: .milliseconds(20))
        let log = SenderEventLog(backend)
        try await backend.connect()

        _ = try await backend.loadConversations()
        try await awaitPolls(3, on: transport)
        let events = await log.settle()

        #expect(presences(in: events) == [
            ada: [.active, LocalBridgeBackend.absentPresence],
            grace: [.inactive]
        ])
        await backend.disconnect()
    }

    /// One error per run of failures, not one every interval.
    @Test func failuresAreReportedOncePerRun() async throws {
        let transport = try transport([
            .failure, .failure, .people(["u-1": .active]), .failure
        ], dmMembers: ["u-1"])
        let backend = backend(transport, interval: .milliseconds(20))
        let log = SenderEventLog(backend)
        try await backend.connect()

        _ = try await backend.loadConversations()
        try await awaitPolls(6, on: transport)
        let events = await log.settle()

        #expect(pollErrors(in: events) == 2)
        #expect(presences(in: events)[ada] == [.active])
        await backend.disconnect()
    }

    // MARK: - Stopping

    @Test func disconnectStopsThePoll() async throws {
        let transport = try transport([.people(["u-1": .active])], dmMembers: ["u-1"])
        let backend = backend(transport, interval: .milliseconds(20))
        let log = SenderEventLog(backend)
        try await backend.connect()
        _ = try await backend.loadConversations()
        // Positive control: the poll really is repeating before the disconnect.
        try await awaitPolls(2, on: transport)

        await backend.disconnect()
        _ = await log.settle()
        let afterDisconnect = await transport.polls.count
        _ = await log.settle()

        #expect(await transport.polls.count == afterDisconnect)
    }

    /// An answer that lands after `disconnect()` belongs to a session that has
    /// gone. Deleting the cancellation check after the call turns this red.
    @Test func anAnswerThatLandsAfterDisconnectEmitsNothing() async throws {
        let transport = try transport([.people(["u-1": .active])], dmMembers: ["u-1"], heldPolls: 1)
        let backend = backend(transport)
        let log = SenderEventLog(backend)
        try await backend.connect()
        _ = try await backend.loadConversations()
        // Positive control: the poll is in flight, so "nothing emitted" below
        // is not "nothing asked".
        try await awaitPolls(1, on: transport)

        await backend.disconnect()
        await transport.release()
        let events = await log.settle()

        #expect(presences(in: events).isEmpty)
    }

    /// A world reload replaces the poll rather than adding a second one: the
    /// first poll's answer, held until after the reload, emits nothing.
    /// Deleting the cancel in `startPresencePoll` turns this red.
    @Test func aWorldReloadReplacesThePoll() async throws {
        // The held first poll takes its answer only once released, so the
        // reload's poll takes the first one here.
        let transport = try transport(
            [.people(["u-1": .active]), .people(["u-1": .inactive])], dmMembers: ["u-1"], heldPolls: 1
        )
        let backend = backend(transport)
        let log = SenderEventLog(backend)
        try await backend.connect()

        _ = try await backend.loadConversations()
        try await awaitPolls(1, on: transport)
        _ = try await backend.loadConversations()
        try await awaitPolls(2, on: transport)
        _ = await log.settle()
        await transport.release()
        let events = await log.settle()

        #expect(presences(in: events)[ada] == [.active])
        await backend.disconnect()
    }
}
