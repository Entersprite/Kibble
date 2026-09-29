import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// The `get_user_presence` poll: who is asked, when, and what reaches the
/// event stream.
@Suite(.timeLimit(.minutes(1)))
struct PresencePollTests: PresencePollFixtures {
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

    /// People are asked about; apps, and kinds this build cannot name, are not.
    @Test func onlyPeopleAreTargets() {
        let members = [
            ChatKit.Member(id: grace, kind: .human),
            ChatKit.Member(id: ChatKit.Member.ID("bot"), kind: .app),
            ChatKit.Member(id: ChatKit.Member.ID("x"), kind: .unknown("ROBOT")),
            ChatKit.Member(id: ada, kind: .human)
        ]
        #expect(LocalBridgeBackend.presenceTargets(from: members) == [ada, grace])
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
        // The last failure withdraws what the success showed.
        #expect(presences(in: events)[ada] == [.active, LocalBridgeBackend.absentPresence])
        await backend.disconnect()
    }

    /// A failed poll cannot confirm anything it showed, so it withdraws it,
    /// and the next success shows it again. Otherwise one success followed by
    /// failures would leave the dots on that answer for the life of the
    /// process. Deleting the withdrawal turns this red.
    @Test func aFailedPollWithdrawsWhatItShowed() async throws {
        let transport = try transport([
            .people(["u-1": .active]), .failure, .people(["u-1": .active])
        ], dmMembers: ["u-1"])
        let backend = backend(transport, interval: .milliseconds(20))
        let log = SenderEventLog(backend)
        try await backend.connect()

        _ = try await backend.loadConversations()
        try await awaitPolls(3, on: transport)
        let events = await log.settle()

        #expect(presences(in: events)[ada] == [.active, LocalBridgeBackend.absentPresence, .active])
        await backend.disconnect()
    }

    /// `.setPresence` is an UPDATE, so presence for someone with no member row
    /// yet is dropped - and deduplication would then never send it again.
    /// The first poll therefore waits for the world load's name lookup, which
    /// is what writes those rows. Deleting the wait turns this red.
    @Test func theFirstPollWaitsForTheNameLookup() async throws {
        let transport = try transport([.people(["u-1": .active])], dmMembers: ["u-1"], heldLookups: 1)
        let backend = backend(transport)
        let log = SenderEventLog(backend)
        try await backend.connect()

        _ = try await backend.loadConversations()
        _ = await log.settle()
        // Positive control: the lookup really is still out.
        #expect(await transport.lookupsAnswered == 0)
        #expect(await transport.polls.isEmpty)

        await transport.release()
        try await awaitPolls(1, on: transport)
        let events = await log.settle()

        let named = try #require(events.firstIndex {
            if case .membersChanged = $0 {
                return true
            }
            return false
        })
        let presence = try #require(events.firstIndex {
            if case .presenceChanged = $0 {
                return true
            }
            return false
        })
        #expect(named < presence)
        await backend.disconnect()
    }

    // MARK: - Stopping

    /// A terminal channel stop ends the session without `disconnect()`, whose
    /// guard then returns early - so the stop itself must end the poll, or it
    /// calls Google every interval until relaunch and its events overwrite
    /// the channel's own error. Deleting the stop in `channelStopped` turns
    /// this red.
    @Test func aTerminalChannelStopStopsThePoll() async throws {
        let transport = try transport([.people(["u-1": .active])], dmMembers: ["u-1"], terminalStream: true)
        let backend = backend(transport, interval: .milliseconds(20))
        let log = SenderEventLog(backend)
        try await backend.connect()
        _ = try await backend.loadConversations()
        // Positive control: the poll really is repeating before the stop.
        try await awaitPolls(2, on: transport)

        await transport.openStream()
        await backend.waitForChannel()
        _ = await log.settle()
        let afterStop = await transport.polls.count
        _ = await log.settle()

        #expect(await transport.polls.count == afterStop)
    }

    /// A failure that lands after `disconnect()` is not news. Deleting the
    /// cancellation check in the failure path turns this red.
    @Test func aFailureThatLandsAfterDisconnectIsNotReported() async throws {
        let transport = try transport([.failure], dmMembers: ["u-1"], heldPolls: 1)
        let backend = backend(transport)
        let log = SenderEventLog(backend)
        try await backend.connect()
        _ = try await backend.loadConversations()
        try await awaitPolls(1, on: transport)

        await backend.disconnect()
        await transport.release()
        try await awaitAnswered(1, on: transport)
        let events = await log.settle()

        #expect(pollErrors(in: events) == 0)
    }

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
        try await awaitAnswered(1, on: transport)
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
        try await awaitAnswered(2, on: transport)
        let events = await log.settle()

        #expect(presences(in: events)[ada] == [.active])
        await backend.disconnect()
    }
}
