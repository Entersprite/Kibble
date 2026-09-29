import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// `send(.markRead(...))`, reached through a real `connect()` - the same shape
/// `SendMessageTests.swift` uses for `.sendMessage`.
private actor RoutingTransport: HTTPTransport {
    struct NoStream: Error {}

    private let shell: HTTPResponse
    private let markReadResponse: HTTPResponse
    private let markReadFailure: (any Error)?
    private(set) var sent: [HTTPRequest] = []

    init(
        shell: HTTPResponse,
        markReadResponse: HTTPResponse,
        markReadFailure: (any Error)? = nil
    ) {
        self.shell = shell
        self.markReadResponse = markReadResponse
        self.markReadFailure = markReadFailure
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        sent.append(request)
        if request.url.path.contains("/mole/world") {
            return shell
        }
        if request.url.path.contains("/api/mark_group_readstate") {
            if let markReadFailure {
                throw markReadFailure
            }
            return markReadResponse
        }
        return HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data())
    }

    func stream(_: HTTPRequest) async throws -> HTTPStream {
        throw NoStream()
    }
}

@Suite(.timeLimit(.minutes(1)))
struct MarkReadTests {
    private static let cookies = SessionCookies(header: "SID=a; COMPASS=b; OSID=c")!

    private func shellResponse(app: String = "DynamiteWebUi") -> HTTPResponse {
        let html = LocalBridgeBackendTests.shell(app: app)
        return HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data(html.utf8))
    }

    private func spaceGroup(_ id: String) -> GroupId {
        var space = SpaceId()
        space.spaceID = id
        var group = GroupId()
        group.spaceID = space
        return group
    }

    /// A response carrying the server's own numbers - which is the whole point:
    /// `unreadCount` has exactly one source of truth and it is not this client.
    private func readStateResponse(
        group: GroupId,
        lastReadMicros: Int64?,
        unread: Int64
    ) throws -> HTTPResponse {
        var state = GroupReadState()
        var identifier = GroupReadStateId()
        identifier.groupID = group
        state.id = identifier
        if let lastReadMicros {
            state.lastReadTime = lastReadMicros
        }
        state.unreadMessageCount = unread

        var response = MarkGroupReadstateResponse()
        response.readState = state
        return try HTTPResponse(
            status: 200, headers: HTTPHeaders([]), body: response.serializedBytes()
        )
    }

    private func backend(_ transport: RoutingTransport) -> LocalBridgeBackend {
        LocalBridgeBackend(cookies: Self.cookies, transport: transport)
    }

    @Test func theBridgeNowAdvertisesThatItCanMarkRead() throws {
        let transport = try RoutingTransport(
            shell: shellResponse(),
            markReadResponse: readStateResponse(
                group: spaceGroup("s-1"), lastReadMicros: 1, unread: 0
            )
        )
        #expect(backend(transport).capabilities.canMarkRead)
    }

    /// The bytes on the wire are `ReadStateRequests.markGroupRead`'s own
    /// serialisation, so an edit that changes what production sends cannot
    /// pass silently. Same shape as `SendMessageTests`'s equivalent assertion.
    ///
    /// **Pinned one microsecond past the `Date`'s own conversion** -
    /// `LocalBridgeBackend.readPositionOffsetMicroseconds`. This is a
    /// **regression test for a confirmed protocol fact**, not a pin on an
    /// experiment: the server's read comparison is strictly-greater-than, so
    /// a position equal to a message's own `create_time` leaves that message
    /// unread for its own sender. Measured and confirmed against live traffic
    /// - `findings.md` §36, and that constant's own doc comment.
    /// The literal here is written out rather than as
    /// `1_700_000_000_000_000 + 1`: an arithmetic literal on the right of
    /// `==` inside `#expect` is typed on its own and would not take its type
    /// from the left-hand side the way ordinary Swift does.
    @Test func markReadPostsTheReferencesShape() async throws {
        let group = spaceGroup("s-1")
        let transport = try RoutingTransport(
            shell: shellResponse(),
            markReadResponse: readStateResponse(
                group: group, lastReadMicros: 1_700_000_000_000_000, unread: 0
            )
        )
        let backend = backend(transport)
        try await backend.connect()
        try await backend.send(.markRead(
            conversationID: Conversation.ID("space/s-1"),
            upTo: Date(timeIntervalSince1970: 1_700_000_000)
        ))

        let sent = await transport.sent
        let request = try #require(sent.first {
            $0.url.path.contains("/api/mark_group_readstate")
        })
        let expected: Data = try ReadStateRequests.markGroupRead(
            group: group, lastReadTime: 1_700_000_000_000_001
        ).serializedBytes()
        #expect(request.body == expected)
    }

    /// **The server decides what the badge says.** The event carries the
    /// response's own `last_read_time` and `unread_message_count`, not the
    /// values this client asked for - a deliberate non-zero unread here is
    /// what makes the difference observable.
    @Test func theResponsesOwnNumbersBecomeTheEvent() async throws {
        let transport = try RoutingTransport(
            shell: shellResponse(),
            markReadResponse: readStateResponse(
                group: spaceGroup("s-1"),
                lastReadMicros: 1_700_000_000_000_000,
                unread: 3
            )
        )
        let backend = backend(transport)
        var iterator = backend.events.makeAsyncIterator()
        try await backend.connect()
        try await backend.send(.markRead(
            conversationID: Conversation.ID("space/s-1"),
            upTo: Date(timeIntervalSince1970: 1)
        ))

        var seen: ChatEvent?
        while let event = await iterator.next() {
            if case .readStateChanged = event {
                seen = event
                break
            }
        }
        guard case let .readStateChanged(conversationID, lastReadAt, unread) = seen else {
            Issue.record("expected .readStateChanged, got \(String(describing: seen))")
            return
        }
        #expect(conversationID.rawValue == "space/s-1")
        #expect(lastReadAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(unread == 3)
    }

    /// **HTTP 200 proves nothing on this protocol.** A mark that quietly did
    /// not happen would leave a badge that never clears with nothing reported.
    @Test func aTwoHundredWithNoReadStateThrows() async throws {
        var empty = MarkGroupReadstateResponse()
        empty.userRevision = WriteRevision()
        let transport = try RoutingTransport(
            shell: shellResponse(),
            markReadResponse: HTTPResponse(
                status: 200, headers: HTTPHeaders([]), body: empty.serializedBytes()
            )
        )
        let backend = backend(transport)
        try await backend.connect()
        await #expect(throws: (any Error).self) {
            try await backend.send(.markRead(
                conversationID: Conversation.ID("space/s-1"),
                upTo: Date(timeIntervalSince1970: 1)
            ))
        }
    }

    /// **Presence decides, never the value.** A read state with no
    /// `last_read_time` would read as 0, which is 1970, and turn every
    /// mention in the conversation unread. No event, and the mark does not
    /// fail: it was accepted. `disconnect()`'s own event is the sentinel that
    /// ends the drain, so nothing here waits on a clock.
    @Test func aReadStateWithNoLastReadTimeEmitsNoPosition() async throws {
        let transport = try RoutingTransport(
            shell: shellResponse(),
            markReadResponse: readStateResponse(group: spaceGroup("s-1"), lastReadMicros: nil, unread: 0)
        )
        let backend = backend(transport)
        var iterator = backend.events.makeAsyncIterator()
        try await backend.connect()
        try await backend.send(.markRead(
            conversationID: Conversation.ID("space/s-1"),
            upTo: Date(timeIntervalSince1970: 1)
        ))
        // Positive control: the mark really was sent.
        #expect(await transport.sent.contains { $0.url.path.contains("/api/mark_group_readstate") })
        await backend.disconnect()

        var readStates = 0
        while let event = await iterator.next() {
            if case .readStateChanged = event {
                readStates += 1
            }
            if case .connectionStateChanged(.disconnected(reason: nil, issue: nil)) = event {
                break
            }
        }
        #expect(readStates == 0)
    }

    @Test func markReadFailsForAConversationIDWithNeitherPrefix() async throws {
        let transport = try RoutingTransport(
            shell: shellResponse(),
            markReadResponse: readStateResponse(
                group: spaceGroup("s-1"), lastReadMicros: 1, unread: 0
            )
        )
        let backend = backend(transport)
        try await backend.connect()
        await #expect(throws: (any Error).self) {
            try await backend.send(.markRead(
                conversationID: Conversation.ID("s-1"),
                upTo: Date(timeIntervalSince1970: 1)
            ))
        }
    }

    /// `Microseconds.from(_:)` saturates at `Int64.max` for a `Date` outside
    /// its range, and `Int64.max + 1` traps under Swift's ordinary `+` - so a
    /// `Date` this far in the future must not crash the app just because the
    /// mark-read boundary experiment adds its offset on top. Regression
    /// coverage for `Microseconds.adding(_:to:)`, the guard that keeps this a
    /// clamp rather than a runtime crash.
    @Test func markReadNeverTrapsWhenTheDateSaturatesInt64Max() async throws {
        let group = spaceGroup("s-1")
        let transport = try RoutingTransport(
            shell: shellResponse(),
            markReadResponse: readStateResponse(group: group, lastReadMicros: .max, unread: 0)
        )
        let backend = backend(transport)
        try await backend.connect()
        // `1e17` seconds since the epoch is finite (nowhere near
        // `Double.greatestFiniteMagnitude`, which would overflow the `* 1e6`
        // multiplication itself to `.infinity` and take the *other* branch in
        // `Microseconds.from(_:)`), but its microsecond value comfortably
        // exceeds `Int64.max` - exactly the input that already saturates
        // `from(_:)` and would then trap under plain `+` when the offset is
        // added on top.
        try await backend.send(.markRead(
            conversationID: Conversation.ID("space/s-1"),
            upTo: Date(timeIntervalSince1970: 1e17)
        ))

        let sent = await transport.sent
        let request = try #require(sent.first {
            $0.url.path.contains("/api/mark_group_readstate")
        })
        let expected: Data = try ReadStateRequests.markGroupRead(
            group: group, lastReadTime: .max
        ).serializedBytes()
        #expect(request.body == expected)
    }

    @Test func markReadBeforeConnectThrows() async throws {
        let transport = try RoutingTransport(
            shell: shellResponse(),
            markReadResponse: readStateResponse(
                group: spaceGroup("s-1"), lastReadMicros: 1, unread: 0
            )
        )
        await #expect(throws: (any Error).self) {
            try await backend(transport).send(.markRead(
                conversationID: Conversation.ID("space/s-1"),
                upTo: Date(timeIntervalSince1970: 1)
            ))
        }
    }
}
