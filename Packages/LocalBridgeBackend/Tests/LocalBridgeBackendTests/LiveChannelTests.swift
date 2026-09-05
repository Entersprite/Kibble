import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// The bridge with a live channel behind it.
///
/// This is the join: `ChannelSession` delivers arrays, `ChannelEventMapping`
/// translates them, and the backend puts the result on the stream `SyncEngine`
/// consumes. Everything either side of it is tested elsewhere; what is tested
/// here is that they are wired together and that the lifetimes line up.
///
/// **The former "Failing" section moved to `LiveChannelFailureTests`** once
/// fix round 1's Finding 3 fix and its two covering tests pushed this file
/// past swiftlint's 400-line ceiling. What remains here covers real traffic
/// reaching the domain and the channel stopping cleanly; that file covers
/// the channel failing.
@Suite(.timeLimit(.minutes(1)))
struct LiveChannelTests {
    private static let cookies = SessionCookies(header: "SID=a; COMPASS=b; OSID=c")!
    private static let initialResponse = #"[[0,["c","S3ss10n","",8,12,30000]]]"#

    private func shell() -> Result<HTTPResponse, any Error> {
        ScriptedTransport.ok(LocalBridgeBackendTests.shell(app: "DynamiteWebUi"))
    }

    /// A `MESSAGE_POSTED` chunk in the shape §12 recorded, framed for the wire.
    private func messageChunk(aid: Int, text: String) -> String {
        let group = #"[null,null,["dm-1"]]"#
        let topic = #"[null,"t-1",\#(group)]"#
        let parent = "[null,null,null,\(topic)]"
        let identifier = #"[\#(parent),"m-\#(aid)"]"#
        let padding = Array(repeating: "null", count: 6).joined(separator: ",")
        let message = #"[\#(identifier),[["u-1"]],"1700000000000000",\#(padding),"\#(text)"]"#
        let body = "[null,null,null,null,null,[\(message)],null,null,null,null,null,6]"
        let event = "[null,null,null,null,null,null,null,[\(body)]]"
        let payload = #"[[\#(event),"wrapper"]]"#
        let array = "[[\(aid),\(payload)]]"
        return "\(array.utf16.count)\n\(array)"
    }

    private func collect(_ backend: LocalBridgeBackend, _ count: Int) async -> [ChatEvent] {
        var iterator = backend.events.makeAsyncIterator()
        var events: [ChatEvent] = []
        for _ in 0 ..< count {
            guard let event = await iterator.next() else { break }
            events.append(event)
        }
        return events
    }

    /// Collects every event emitted within `duration`, rather than a fixed
    /// count.
    ///
    /// `connect()` now races the channel's handshake against
    /// `resolveAndEmitSelf()`, both concurrent and both consuming this
    /// suite's finite scripted responses - so how many events a given run
    /// emits, and in what order, is no longer fixed the way a purely
    /// sequential `connect()` used to make it. A fixed `collect(_:_:)` count
    /// either cuts off before a late event arrives, or - the version that
    /// actually happened here - hangs forever asking for one more event than
    /// this finite scenario will ever produce, timing out the whole suite.
    /// Same shape and same reasoning as
    /// `LoadConversationsMemberResolutionTests.collectEvents`.
    private func collectEvents(
        _ backend: LocalBridgeBackend,
        for duration: Duration = .milliseconds(300)
    ) async -> [ChatEvent] {
        let collector = Task<[ChatEvent], Never> {
            var events: [ChatEvent] = []
            for await event in backend.events {
                events.append(event)
            }
            return events
        }
        try? await Task.sleep(for: duration)
        collector.cancel()
        return await collector.value
    }

    // MARK: - Real traffic reaching the domain

    @Test func aPostedMessageOnTheChannelReachesTheEventStream() async throws {
        // Five non-shell responses, generously: `connect()` also starts
        // `resolveAndEmitSelf()`, racing the channel's own `register()`,
        // `acknowledge()` (because a chunk arrives below) and - Part 1's
        // addition - the initial ping, all for the same scripted queue.
        // Content does not matter to any of the four - `register`/
        // `acknowledge`/the ping ignore it and a failed
        // `get_self_user_status` only produces a harmless `.backendError` -
        // but there must be enough of it, or whichever call loses the race
        // gets `Exhausted()` and the channel this test is actually about
        // never opens. See the slice report for the exact failure text that
        // produced.
        let transport = ScriptedTransport(
            [shell()] + Array(repeating: ScriptedTransport.ok(""), count: 5),
            streams: [
                ScriptedTransport.Script(
                    headers: HTTPHeaders([("X-HTTP-Initial-Response", Self.initialResponse)]),
                    chunks: [messageChunk(aid: 1, text: "hello from the wire")]
                )
            ]
        )
        let backend = LocalBridgeBackend(cookies: Self.cookies, transport: transport)
        try await backend.connect()

        // Not a fixed count: the message is *found* within whatever landed in
        // the window, rather than assumed at a particular index. See
        // `collectEvents`'s own doc comment for why a fixed count broke here.
        let received = await collectEvents(backend)
        let posted = received.first {
            if case .messageReceived = $0 {
                return true
            }
            return false
        }
        guard case let .messageReceived(message) = posted else {
            Issue.record("no .messageReceived in \(received.count) events: \(received)")
            return
        }
        #expect(message.text == "hello from the wire")
        #expect(message.conversationID.rawValue == "dm/dm-1")
        // Since task 3 of the reconnect taxonomy the channel's reopen (which
        // has no further script here) reconnects forever rather than
        // stopping, so an explicit `disconnect()` is what ends it - without
        // this the channel task would keep retrying in the background for
        // the rest of the test run.
        await backend.disconnect()
    }

    /// Connecting still reports itself before anything arrives, so a window has
    /// something true to show while the handshake is in flight.
    @Test func connectingStillAnnouncesItselfBeforeTheChannelOpens() async throws {
        let transport = ScriptedTransport(
            // Five, generously - see `aPostedMessageOnTheChannelReachesTheEventStream`'s
            // own comment for why four real consumers race this queue.
            [shell()] + Array(repeating: ScriptedTransport.ok(""), count: 5),
            streams: [
                ScriptedTransport.Script(
                    headers: HTTPHeaders([("X-HTTP-Initial-Response", Self.initialResponse)]),
                    chunks: []
                )
            ]
        )
        let backend = LocalBridgeBackend(cookies: Self.cookies, transport: transport)
        async let events = collect(backend, 2)
        try await backend.connect()
        #expect(await events == [
            .connectionStateChanged(.connecting),
            .connectionStateChanged(.connected)
        ])
        // Since task 3 of the reconnect taxonomy the channel's reopen (which
        // has no further script here) reconnects forever rather than
        // stopping, so an explicit `disconnect()` is what ends it.
        await backend.disconnect()
    }

    /// `connect()` must not sit on the long poll. It returns once the session is
    /// verified and the channel is running, or a caller would block until the
    /// account signed out.
    @Test func connectReturnsWithoutWaitingForTheChannelToFinish() async throws {
        // Five non-shell responses - see
        // `aPostedMessageOnTheChannelReachesTheEventStream`'s own comment for
        // why four real consumers race this queue.
        let transport = ScriptedTransport(
            [shell()] + Array(repeating: ScriptedTransport.ok(""), count: 5),
            streams: [
                ScriptedTransport.Script(
                    headers: HTTPHeaders([("X-HTTP-Initial-Response", Self.initialResponse)]),
                    chunks: [messageChunk(aid: 1, text: "a")]
                )
            ]
        )
        let backend = LocalBridgeBackend(cookies: Self.cookies, transport: transport)
        try await backend.connect()
        #expect(await backend.isRunningChannel)
        // Since task 3 of the reconnect taxonomy the channel's reopen (which
        // has no further script here) reconnects forever rather than
        // stopping, so an explicit `disconnect()` is what ends it.
        await backend.disconnect()
    }

    // MARK: - Stopping

    @Test func disconnectingStopsTheChannel() async throws {
        let transport = ScriptedTransport(
            // Five, generously - see `aPostedMessageOnTheChannelReachesTheEventStream`'s
            // own comment for why four real consumers race this queue.
            [shell()] + Array(repeating: ScriptedTransport.ok(""), count: 5),
            streams: [
                ScriptedTransport.Script(
                    headers: HTTPHeaders([("X-HTTP-Initial-Response", Self.initialResponse)]),
                    chunks: []
                )
            ]
        )
        let backend = LocalBridgeBackend(cookies: Self.cookies, transport: transport)
        try await backend.connect()
        await backend.disconnect()
        #expect(await !backend.isRunningChannel)
    }

    /// A channel that is no longer the current one must not be able to close
    /// the session that replaced it.
    ///
    /// `channelStopped` took the channel as a parameter and then ignored it,
    /// guarding only on `channelTask != nil`. A `disconnect()` → `connect()`
    /// sequence leaves the old task still unwinding, so its late
    /// `channelStopped` would nil `channelTask`, `channel`, `isConnected` and
    /// `apiClient` out from under the new session - a session that connects
    /// and immediately reports itself disconnected, with a live long poll
    /// still running and nothing reading it.
    ///
    /// Called directly rather than raced, because the race is exactly what a
    /// test cannot schedule. The straggler here is a `ChannelSession` this
    /// backend has never heard of, which is indistinguishable to
    /// `channelStopped` from one it has retired.
    @Test func aStragglingChannelDoesNotStopTheCurrentSession() async throws {
        let transport = ScriptedTransport(
            // Five, generously - see `aPostedMessageOnTheChannelReachesTheEventStream`'s
            // own comment for why four real consumers race this queue.
            [shell()] + Array(repeating: ScriptedTransport.ok(""), count: 5),
            streams: [
                ScriptedTransport.Script(
                    headers: HTTPHeaders([("X-HTTP-Initial-Response", Self.initialResponse)]),
                    chunks: []
                )
            ]
        )
        let backend = LocalBridgeBackend(cookies: Self.cookies, transport: transport)
        try await backend.connect()
        #expect(await backend.isRunningChannel)

        let straggler = ChannelSession(cookies: Self.cookies, transport: ScriptedTransport([]))
        await backend.channelStopped(straggler)

        #expect(await backend.isRunningChannel)
        await backend.disconnect()
    }
}
