import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// A transport that routes by URL rather than by call order.
///
/// `connect()` starts a real `ChannelSession` in the background, which races
/// a real `/api/` call for the shared `ScriptedTransport`'s FIFO queue - a
/// channel `register()` and a `loadConversations()` call's own `send()` are
/// indistinguishable to a plain ordered queue, and which one gets which
/// scripted response is not guaranteed by anything in `Task` scheduling. This
/// removes the race by keying on the URL instead, the way a real HTTP
/// transport would: the bootstrap gets its shell, `/api/` gets the crafted
/// response, and everything the channel needs gets something that lets it
/// fail quickly and harmlessly - what `LoadConversationsTests` is testing is
/// `loadConversations()`, not the channel.
private actor RoutingTransport: HTTPTransport {
    struct NoStream: Error {}

    private let shell: HTTPResponse
    private let apiResponse: HTTPResponse

    init(shell: HTTPResponse, apiResponse: HTTPResponse) {
        self.shell = shell
        self.apiResponse = apiResponse
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        if request.url.path.contains("/mole/world") {
            return shell
        }
        if request.url.path.contains("/api/") {
            return apiResponse
        }
        // The channel's `register()`/`acknowledge()` - neither reads its
        // response body, so a bare 200 is enough.
        return HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data())
    }

    func stream(_: HTTPRequest) async throws -> HTTPStream {
        // The channel's handshake/reopen. Failing it here is deliberate -
        // it lets the channel end on its own quickly, which is not what
        // this suite is testing.
        throw NoStream()
    }
}

/// `loadConversations()` after a real `connect()`, against `RoutingTransport`
/// above.
@Suite(.timeLimit(.minutes(1)))
struct LoadConversationsTests {
    private static let cookies = SessionCookies(header: "SID=a; COMPASS=b; OSID=c")!

    private func shellResponse(app: String) -> HTTPResponse {
        let html = LocalBridgeBackendTests.shell(app: app)
        return HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data(html.utf8))
    }

    private func spaceGroupID(_ id: String) -> GroupId {
        var group = GroupId()
        var space = SpaceId()
        space.spaceID = id
        group.spaceID = space
        return group
    }

    private func worldItem(spaceID: String, roomName: String) -> WorldItemLite {
        var item = WorldItemLite()
        item.groupID = spaceGroupID(spaceID)
        item.roomName = roomName
        return item
    }

    private func apiResponse(items: [WorldItemLite], status: Int = 200) throws -> HTTPResponse {
        var response = PaginatedWorldResponse()
        response.worldItems = items
        return try HTTPResponse(status: status, headers: HTTPHeaders([]), body: response.serializedBytes())
    }

    private func backend(apiResponse: HTTPResponse, app: String = "DynamiteWebUi") -> LocalBridgeBackend {
        LocalBridgeBackend(
            cookies: Self.cookies,
            transport: RoutingTransport(shell: shellResponse(app: app), apiResponse: apiResponse)
        )
    }

    // MARK: - Somebody has to ask

    /// **The bug this catches produced an empty sidebar and no error.**
    ///
    /// `SyncEngine` reaches `loadConversations()` only through the
    /// `.reloadConversations` effect, and `SyncReducer` produces that effect
    /// only for `gap(scope: .everything)`. So a `connect()` that does not emit
    /// one leaves the conversation list implemented, correct, and never called
    /// - and nothing anywhere reports a problem, because nothing failed.
    ///
    /// `FakeBackend` pushes a snapshot instead; the bridge pulls, so the gap is
    /// the whole link between connecting and having a world.
    @Test func connectingEmitsAnEverythingGapSoSomethingAsksForTheWorld() async throws {
        let backend = try backend(apiResponse: apiResponse(items: [
            worldItem(spaceID: "s-1", roomName: "Engineering")
        ]))
        try await backend.connect()

        var sawGap = false
        for await event in backend.events {
            if case let .gap(scope, _) = event, scope == .everything {
                sawGap = true
                break
            }
            if case .backendError = event {
                break
            }
        }
        #expect(sawGap)
    }

    // MARK: - The happy path

    @Test func loadConversationsAfterConnectMapsTheWorldResponse() async throws {
        let backend = try backend(apiResponse: apiResponse(items: [
            worldItem(spaceID: "s-1", roomName: "Engineering")
        ]))
        try await backend.connect()

        let conversations = try await backend.loadConversations()
        #expect(conversations.count == 1)
        #expect(conversations.first?.id.rawValue == "space/s-1")
        #expect(conversations.first?.title == "Engineering")
        #expect(conversations.first?.kind == .space)
    }

    @Test func loadConversationsSkipsUnmappableItemsWithoutThrowing() async throws {
        let backend = try backend(apiResponse: apiResponse(items: [
            worldItem(spaceID: "s-1", roomName: "Kept"),
            worldItem(spaceID: "", roomName: "Dropped - empty space id")
        ]))
        try await backend.connect()

        let conversations = try await backend.loadConversations()
        #expect(conversations.count == 1)
        #expect(conversations.first?.title == "Kept")
    }

    /// A skipped item must not vanish with nothing said - it does not throw
    /// (the call above already covers that), but it has to leave a trace
    /// somewhere the UI's store can see, or a conversation could disappear
    /// from the sidebar across a run with no evidence anything went wrong.
    /// `.backendError(.unknown(...))` carries the **count only** - never the
    /// dropped item's room name or space id.
    @Test func loadConversationsEmitsABackendErrorCountWhenItemsAreSkipped() async throws {
        let droppedName = "Dropped - empty space id"
        let backend = try backend(apiResponse: apiResponse(items: [
            worldItem(spaceID: "s-1", roomName: "Kept"),
            worldItem(spaceID: "", roomName: droppedName)
        ]))
        var iterator = backend.events.makeAsyncIterator()

        try await backend.connect()
        _ = try await backend.loadConversations()

        var found: ChatError?
        for _ in 0 ..< 20 where found == nil {
            guard let event = await iterator.next() else { break }
            if case let .backendError(error) = event, case .unknown = error {
                found = error
            }
        }
        guard case let .unknown(message)? = found else {
            Issue.record("expected a .backendError(.unknown) event reporting the skip count")
            return
        }
        #expect(message.contains("1"))
        #expect(!message.contains(droppedName))
        #expect(!message.contains("s-1"))
    }

    // MARK: - A failing `/api/` call

    @Test func loadConversationsMapsAnHTTPFailureToAChatServerError() async throws {
        let backend = try backend(apiResponse: apiResponse(items: [], status: 500))
        try await backend.connect()

        do {
            _ = try await backend.loadConversations()
            Issue.record("expected loadConversations() to throw on HTTP 500")
        } catch {
            guard case let .server(status, _) = error as? ChatError else {
                Issue.record("expected .server, got \(String(describing: error))")
                return
            }
            #expect(status == 500)
        }
    }
}
