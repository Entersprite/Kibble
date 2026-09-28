import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// Names for people the world response never listed - senders on a history
/// page and on the live channel - looked up with `get_members` on demand.
/// A named space or a Meet chat lists no members (`findings.md` §37.5).
///
/// The transport and fixtures live in `Support/SenderResolutionSupport.swift`,
/// shared with `SenderResolutionSessionTests`.
@Suite(.timeLimit(.minutes(1)))
struct SenderResolutionTests: SenderResolutionFixtures {
    // MARK: - History

    /// The discriminating test: a space's history page names senders nothing
    /// else ever listed. Deleting the lookup in `loadMessages(in:before:)`
    /// turns this red.
    @Test func aHistoryPageLooksUpItsSendersNames() async throws {
        let transport = try SenderRoutingTransport(
            shell: shell(), world: world(), topics: topics(from: ["u-1", "u-2", "u-1"]), names: Self.names
        )
        let backend = LocalBridgeBackend(cookies: Self.cookies, transport: transport)
        let log = SenderEventLog(backend)
        try await backend.connect()

        let messages = try await backend.loadMessages(in: Self.space, before: nil)
        let events = await log.settle()

        #expect(messages.count == 3)
        #expect(resolvedNames(in: events) == ["Ada Lovelace", "Grace Hopper"])
        #expect(await transport.lookups == [["u-1", "u-2"]])
        await backend.disconnect()
    }

    /// The second page of the same senders asks nothing.
    @Test func aSenderAlreadyAskedAboutIsNotAskedAgain() async throws {
        let transport = try SenderRoutingTransport(
            shell: shell(), world: world(), topics: topics(from: ["u-1"]), names: Self.names
        )
        let backend = LocalBridgeBackend(cookies: Self.cookies, transport: transport)
        let log = SenderEventLog(backend)
        try await backend.connect()

        _ = try await backend.loadMessages(in: Self.space, before: nil)
        _ = await log.settle()
        _ = try await backend.loadMessages(in: Self.space, before: nil)
        _ = await log.settle()

        #expect(await transport.lookups == [["u-1"]])
        await backend.disconnect()
    }

    /// Members the world load already asked about are not asked again.
    @Test func theWorldLoadsMembersAreNotAskedAgain() async throws {
        let transport = try SenderRoutingTransport(
            shell: shell(),
            world: world(dmMembers: ["u-1"]),
            topics: topics(from: ["u-1", "u-2"]),
            names: Self.names
        )
        let backend = LocalBridgeBackend(cookies: Self.cookies, transport: transport)
        let log = SenderEventLog(backend)
        try await backend.connect()

        _ = try await backend.loadConversations()
        _ = await log.settle()
        _ = try await backend.loadMessages(in: Self.space, before: nil)
        _ = await log.settle()

        #expect(await transport.lookups == [["u-1"], ["u-2"]])
        await backend.disconnect()
    }

    /// A failed lookup is reported, and forgotten, so the next page asks
    /// again rather than leaving those people unnamed for the whole session.
    @Test func aFailedLookupIsReportedAndRetriedByTheNextPage() async throws {
        let transport = try SenderRoutingTransport(
            shell: shell(), world: world(), topics: topics(from: ["u-1"]), names: Self.names,
            failingLookups: 1
        )
        let backend = LocalBridgeBackend(cookies: Self.cookies, transport: transport)
        let log = SenderEventLog(backend)
        try await backend.connect()

        _ = try await backend.loadMessages(in: Self.space, before: nil)
        let first = await log.settle()
        _ = try await backend.loadMessages(in: Self.space, before: nil)
        let second = await log.settle(since: first.count)

        #expect(first.contains {
            if case let .backendError(error) = $0 {
                return "\(error)".contains("get_members")
            }
            return false
        })
        #expect(resolvedNames(in: first).isEmpty)
        #expect(resolvedNames(in: second) == ["Ada Lovelace"])
        #expect(await transport.lookups == [["u-1"], ["u-1"]])
        await backend.disconnect()
    }

    /// A lookup that answers after `disconnect()` belongs to a session that
    /// has gone, and must not land in the next one. Deleting the generation
    /// check in the lookup turns this red.
    @Test func aLookupThatLandsAfterDisconnectEmitsNothing() async throws {
        let transport = try SenderRoutingTransport(
            shell: shell(), world: world(), topics: topics(from: ["u-1"]), names: Self.names,
            heldLookups: 1
        )
        let backend = LocalBridgeBackend(cookies: Self.cookies, transport: transport)
        let log = SenderEventLog(backend)
        try await backend.connect()
        _ = try await backend.loadMessages(in: Self.space, before: nil)
        // Positive control: the lookup really is in flight before the
        // disconnect, so "nothing emitted" below is not "nothing asked".
        try await awaitLookups(1, on: transport)

        await backend.disconnect()
        await transport.release()
        let events = await log.settle()

        #expect(resolvedNames(in: events).isEmpty)
    }

    // MARK: - Live

    /// A typing indicator draws a name too, so a typer is looked up like a sender.
    @Test func sendersAndTypersAreTheIdsAChannelEventNames() {
        let message = ChatKit.Message(
            id: ChatKit.Message.ID("m-1"),
            conversationID: Self.space,
            threadID: MessageThread.ID("t-1"),
            sender: ChatKit.Member.ID("u-1"),
            text: "hi",
            createdAt: Date(timeIntervalSince1970: 0)
        )
        let typer = ChatKit.Member.ID("u-2")
        #expect(LocalBridgeBackend.memberIDs(in: .messageReceived(message)) == [message.sender])
        #expect(LocalBridgeBackend.memberIDs(in: .messageUpdated(message)) == [message.sender])
        #expect(LocalBridgeBackend.memberIDs(
            in: .typingChanged(conversationID: Self.space, member: typer, isTyping: true)
        ) == [typer])
        #expect(LocalBridgeBackend.memberIDs(in: .messageDeleted(id: message.id, in: Self.space)).isEmpty)
    }

    /// A message on the channel from someone never seen before names them.
    @Test func aLiveMessageFromAStrangerLooksUpTheirName() async throws {
        let transport = try SenderRoutingTransport(
            shell: shell(), world: world(), topics: topics(from: []), names: Self.names,
            liveChunk: liveChunk(from: "u-2")
        )
        let backend = LocalBridgeBackend(cookies: Self.cookies, transport: transport)
        let log = SenderEventLog(backend)
        try await backend.connect()

        let events = await log.settle()

        #expect(events.contains {
            if case .messageReceived = $0 {
                return true
            }
            return false
        })
        #expect(resolvedNames(in: events) == ["Grace Hopper"])
        #expect(await transport.lookups == [["u-2"]])
        await backend.disconnect()
    }
}
