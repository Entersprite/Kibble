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

    // MARK: - Real traffic reaching the domain

    @Test func aPostedMessageOnTheChannelReachesTheEventStream() async throws {
        let transport = ScriptedTransport(
            [shell(), ScriptedTransport.ok(""), ScriptedTransport.ok("")],
            streams: [
                ScriptedTransport.Script(
                    headers: HTTPHeaders([("X-HTTP-Initial-Response", Self.initialResponse)]),
                    chunks: [messageChunk(aid: 1, text: "hello from the wire")]
                )
            ]
        )
        let backend = LocalBridgeBackend(cookies: Self.cookies, transport: transport)
        async let events = collect(backend, 3)
        try await backend.connect()

        let received = await events
        #expect(received.count == 3)
        guard case let .messageReceived(message) = received.last else {
            Issue.record("expected .messageReceived, got \(String(describing: received.last))")
            return
        }
        #expect(message.text == "hello from the wire")
        #expect(message.conversationID.rawValue == "dm/dm-1")
    }

    /// Connecting still reports itself before anything arrives, so a window has
    /// something true to show while the handshake is in flight.
    @Test func connectingStillAnnouncesItselfBeforeTheChannelOpens() async throws {
        let transport = ScriptedTransport(
            [shell(), ScriptedTransport.ok(""), ScriptedTransport.ok("")],
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
    }

    /// `connect()` must not sit on the long poll. It returns once the session is
    /// verified and the channel is running, or a caller would block until the
    /// account signed out.
    @Test func connectReturnsWithoutWaitingForTheChannelToFinish() async throws {
        let transport = ScriptedTransport(
            [shell(), ScriptedTransport.ok(""), ScriptedTransport.ok("")],
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
    }

    // MARK: - Failing

    /// A bootstrap that says "signed out" must not go on to open a channel with
    /// credentials that have already been refused.
    @Test func aRejectedSessionOpensNoChannel() async {
        let transport = ScriptedTransport(
            [ScriptedTransport.ok(LocalBridgeBackendTests.shell(app: "AccountsSignInUi"))]
        )
        let backend = LocalBridgeBackend(cookies: Self.cookies, transport: transport)
        _ = try? await backend.connect()
        #expect(await !backend.isRunningChannel)
    }

    /// The channel stopping is not silent. `ChannelSession` reports and stops
    /// rather than reconnecting, so the backend has to say so or the window
    /// shows a session that looks healthy and has stopped delivering.
    @Test func aChannelFailureIsReportedOnTheEventStream() async throws {
        // No streams scripted: the handshake fails, which is what a closed
        // socket looks like.
        let transport = ScriptedTransport([shell(), ScriptedTransport.ok("")])
        let backend = LocalBridgeBackend(cookies: Self.cookies, transport: transport)
        async let events = collect(backend, 4)
        try await backend.connect()

        let received = await events
        #expect(received.contains {
            if case .backendError = $0 {
                true
            } else {
                false
            }
        })
    }

    // MARK: - Stopping

    @Test func disconnectingStopsTheChannel() async throws {
        let transport = ScriptedTransport(
            [shell(), ScriptedTransport.ok(""), ScriptedTransport.ok("")],
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

    // MARK: - Rotation

    /// The whole reason `ChannelSession` takes an `onRotation`: a session that
    /// rotates mid-stream has to be written back, or the next launch replays a
    /// credential that went stale on the first poll.
    @Test func aCookieRotatedOnTheChannelIsHandedToTheCredentialStore() async throws {
        let transport = ScriptedTransport(
            [
                shell(),
                .success(HTTPResponse(
                    status: 200,
                    headers: HTTPHeaders([("Set-Cookie", "COMPASS=grown; Path=/")]),
                    body: Data()
                )),
                ScriptedTransport.ok("")
            ],
            streams: [
                ScriptedTransport.Script(
                    headers: HTTPHeaders([("X-HTTP-Initial-Response", Self.initialResponse)]),
                    chunks: []
                )
            ]
        )
        let rotations = Rotations()
        let backend = LocalBridgeBackend(
            cookies: Self.cookies,
            transport: transport,
            onRotation: { await rotations.record($0) }
        )
        try await backend.connect()
        // Let the channel run to its end so the register response is absorbed.
        await backend.waitForChannel()
        #expect(await rotations.count >= 1)
    }
}

private actor Rotations {
    private(set) var count = 0

    func record(_: SessionCookies) {
        count += 1
    }
}
