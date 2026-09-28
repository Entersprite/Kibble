import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// Sender lookups across a session's edges: a reconnect, a failed world
/// load, a channel that dies, and the signed-in account itself. Split from
/// `SenderResolutionTests` for `file_length`.
@Suite(.timeLimit(.minutes(1)))
struct SenderResolutionSessionTests: SenderResolutionFixtures {
    /// A lookup that fails after `disconnect()` must neither report into the
    /// next session nor leave its ids marked there. Deleting either
    /// `disconnect()`'s clear or the error path's generation check turns
    /// this red.
    @Test func aLookupFailingAcrossAReconnectIsAskedAgainAndReportsNothing() async throws {
        let transport = try SenderRoutingTransport(
            shell: shell(), world: world(), topics: topics(from: ["u-1"]), names: Self.names,
            failingLookups: 1, heldLookups: 1
        )
        let backend = LocalBridgeBackend(cookies: Self.cookies, transport: transport)
        let log = SenderEventLog(backend)
        try await backend.connect()
        _ = try await backend.loadMessages(in: Self.space, before: nil)
        try await awaitLookups(1, on: transport)

        await backend.disconnect()
        let mark = await log.settle().count
        try await backend.connect()
        await transport.release()
        _ = await log.settle(since: mark)
        _ = try await backend.loadMessages(in: Self.space, before: nil)
        let after = await log.settle(since: mark)

        #expect(lookupErrors(in: after) == 0)
        #expect(await transport.lookups == [["u-1"], ["u-1"]])
        #expect(resolvedNames(in: after) == ["Ada Lovelace"])
        await backend.disconnect()
    }

    /// The world load's own failure forgets its ids, so a page retries them.
    @Test func aFailedWorldLookupIsRetriedByTheNextPage() async throws {
        let transport = try SenderRoutingTransport(
            shell: shell(), world: world(dmMembers: ["u-1"]), topics: topics(from: ["u-1"]),
            names: Self.names, failingLookups: 1
        )
        let backend = LocalBridgeBackend(cookies: Self.cookies, transport: transport)
        let log = SenderEventLog(backend)
        try await backend.connect()

        _ = try await backend.loadConversations()
        _ = await log.settle()
        _ = try await backend.loadMessages(in: Self.space, before: nil)
        let events = await log.settle()

        #expect(await transport.lookups == [["u-1"], ["u-1"]])
        #expect(resolvedNames(in: events) == ["Ada Lovelace"])
        await backend.disconnect()
    }

    /// The signed-in account is named like anyone else. The world does not
    /// always list it - an account with no DMs never appears in one - and the
    /// sidebar footer draws its name.
    @Test func theSignedInAccountIsLookedUp() async throws {
        let transport = try SenderRoutingTransport(
            shell: shell(), world: world(), topics: topics(from: []),
            names: ["me-1": "Mark"], selfID: "me-1"
        )
        let backend = LocalBridgeBackend(cookies: Self.cookies, transport: transport)
        let log = SenderEventLog(backend)
        try await backend.connect()

        let events = await log.settle()

        #expect(resolvedNames(in: events) == ["Mark"])
        await backend.disconnect()
    }

    /// A lookup started from the channel, answering after the channel died,
    /// belongs to a session that has ended. If it landed, its
    /// `membersResolved` would clear the error the channel just reported
    /// (`SyncReducer.supersedingStaleError`). Deleting `channelStopped`'s
    /// call to forget the directory turns this red.
    @Test func aLookupThatLandsAfterTheChannelDiesEmitsNothing() async throws {
        let transport = try SenderRoutingTransport(
            shell: shell(), world: world(), topics: topics(from: ["u-1"]), names: Self.names,
            heldLookups: 1, terminalStream: true
        )
        let backend = LocalBridgeBackend(cookies: Self.cookies, transport: transport, retry: .immediate)
        let log = SenderEventLog(backend)
        try await backend.connect()
        _ = try await backend.loadMessages(in: Self.space, before: nil)
        try await awaitLookups(1, on: transport)

        await transport.openStream()
        await backend.waitForChannel()
        await transport.release()
        let events = await log.settle()

        #expect(events.contains {
            if case .connectionStateChanged(.disconnected) = $0 {
                return true
            }
            return false
        })
        #expect(resolvedNames(in: events).isEmpty)
    }
}
