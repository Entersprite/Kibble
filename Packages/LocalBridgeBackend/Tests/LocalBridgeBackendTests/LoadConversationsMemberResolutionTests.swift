import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// `resolveAndEmitMembers`, reached through `loadConversations()` after a
/// real `connect()` - split out of `LoadConversationsTests.swift` once the
/// member-resolution tests pushed that file past `swiftlint`'s `file_length`.
///
/// `RoutingTransport` and its surrounding fixtures are duplicated rather than
/// shared, the same call `LoadConversationsTests.swift`'s own doc comment on
/// `RoutingTransport` already makes and `APIProbeReportWorldMappingTests.swift`
/// makes for the same reason: `private` is `private`, and a little
/// duplication is cheaper than a shared surface neither file actually needs
/// elsewhere.
private actor RoutingTransport: HTTPTransport {
    struct NoStream: Error {}

    private let shell: HTTPResponse
    private let worldResponse: HTTPResponse
    private let membersResponse: HTTPResponse
    /// Thrown from `send()` instead of `membersResponse` when set - lets a
    /// test put a failing `get_members` call in front of `loadConversations()`
    /// without a second transport type.
    private let membersFailure: (any Error)?

    init(
        shell: HTTPResponse,
        worldResponse: HTTPResponse,
        membersResponse: HTTPResponse,
        membersFailure: (any Error)? = nil
    ) {
        self.shell = shell
        self.worldResponse = worldResponse
        self.membersResponse = membersResponse
        self.membersFailure = membersFailure
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        if request.url.path.contains("/mole/world") {
            return shell
        }
        // Checked before the general `/api/` case below - both
        // `paginated_world` and `get_members` live under `/api/`, and only
        // the method name in the path tells them apart.
        if request.url.path.contains("/api/get_members") {
            if let membersFailure {
                throw membersFailure
            }
            return membersResponse
        }
        if request.url.path.contains("/api/") {
            return worldResponse
        }
        // The channel's `register()`/`acknowledge()` - neither reads its
        // response body, so a bare 200 is enough.
        return HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data())
    }

    func stream(_: HTTPRequest) async throws -> HTTPStream {
        // The channel's handshake/reopen. Failing it here is deliberate:
        // this suite is testing `loadConversations()`, not the channel, and
        // it used to end the channel's own task quickly as a side effect.
        // Since the reconnect taxonomy removed the attempt bound, it no
        // longer does - `.transport` is unconditionally recoverable, so this
        // failure now retries forever instead. That leaves the channel task
        // `connect()` started running in the background, orphaned, for the
        // rest of this suite's run. Known and deliberately deferred (see the
        // whole-slice review's fix report), not something this comment
        // should keep claiming isn't happening.
        throw NoStream()
    }
}

@Suite(.timeLimit(.minutes(1)))
struct LoadConversationsMemberResolutionTests {
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

    private func dmGroupID(_ id: String) -> GroupId {
        var group = GroupId()
        var dm = DmId()
        dm.dmID = id
        group.dmID = dm
        return group
    }

    /// A DM `WorldItemLite` carrying real `dm_members` - what
    /// `resolveAndEmitMembers` needs to have anything to resolve, unlike
    /// `worldItem(spaceID:roomName:)` above, which leaves `dm_members` unset.
    private func dmWorldItem(dmID: String, memberIDs: [String]) -> WorldItemLite {
        var item = WorldItemLite()
        item.groupID = dmGroupID(dmID)
        var members = WorldItemLite.DmMembers()
        members.members = memberIDs.map { id in
            var userID = UserId()
            userID.id = id
            return userID
        }
        item.dmMembers = members
        return item
    }

    private func apiResponse(items: [WorldItemLite], status: Int = 200) throws -> HTTPResponse {
        var response = PaginatedWorldResponse()
        response.worldItems = items
        return try HTTPResponse(status: status, headers: HTTPHeaders([]), body: response.serializedBytes())
    }

    private func emptyMembersResponse() throws -> HTTPResponse {
        try HTTPResponse(status: 200, headers: HTTPHeaders([]), body: GetMembersResponse().serializedBytes())
    }

    /// A `GetMembersResponse` carrying one named `User` per `(id, name)` pair
    /// - built as typed `SwiftProtobuf` values, the same convention
    /// `WorldMappingTests`/`MemberMappingTests` use.
    private func membersResponse(_ entries: [(id: String, name: String)]) throws -> HTTPResponse {
        var response = GetMembersResponse()
        response.members = entries.map { entry in
            var userID = UserId()
            userID.id = entry.id
            var user = User()
            user.userID = userID
            user.name = entry.name
            var member = GChatBridgeCore.Member()
            member.user = user
            return member
        }
        return try HTTPResponse(status: 200, headers: HTTPHeaders([]), body: response.serializedBytes())
    }

    /// Collects every event emitted within `duration`, rather than a fixed
    /// count.
    ///
    /// `connect()` starts the channel in the background, and this backend is
    /// an `actor` - reentrant across its own `await` points - so the
    /// channel's own concurrent, unrelated failure (`RoutingTransport.stream()`
    /// always throws `NoStream`) can land its events at any point during
    /// `loadConversations()`'s awaits, not only after it returns. A fixed
    /// count assumes an ordering this scenario does not actually guarantee:
    /// it either hangs waiting for an event count this run never reaches, or
    /// - as this file's own discrimination check recorded - stops looking
    /// before an event that arrived late (see the slice report for the exact
    /// failure text that produced). Racing a short timeout instead tolerates
    /// the interleaving and still fails in well under a second when the
    /// event never comes.
    private func collectEvents(
        _ backend: LocalBridgeBackend,
        for duration: Duration = .milliseconds(200)
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

    private func backend(
        apiResponse: HTTPResponse,
        membersResponse: HTTPResponse? = nil,
        membersFailure: (any Error)? = nil,
        app: String = "DynamiteWebUi"
    ) throws -> LocalBridgeBackend {
        try LocalBridgeBackend(
            cookies: Self.cookies,
            transport: RoutingTransport(
                shell: shellResponse(app: app),
                worldResponse: apiResponse,
                membersResponse: membersResponse ?? emptyMembersResponse(),
                membersFailure: membersFailure
            )
        )
    }

    // MARK: - Member resolution

    /// The discriminating test: a conversation with real `dm_members` gets a
    /// `.membersChanged` carrying the names `get_members` mapped, keyed to
    /// the right conversation. Deliberately breaking the
    /// `emit(.membersChanged(...))` call in `resolveAndEmitMembers` and
    /// re-running this turns it red - see the slice report for the exact
    /// failure text that produced.
    @Test func loadConversationsEmitsMembersChangedWithMappedNames() async throws {
        let backend = try backend(
            apiResponse: apiResponse(items: [
                dmWorldItem(dmID: "d-1", memberIDs: ["u-1", "u-2"])
            ]),
            membersResponse: membersResponse([
                (id: "u-1", name: "Ada Lovelace"),
                (id: "u-2", name: "Grace Hopper")
            ])
        )
        try await backend.connect()
        _ = try await backend.loadConversations()

        let events = await collectEvents(backend)
        let found: (Conversation.ID, [ChatKit.Member])? = events.compactMap {
            if case let .membersChanged(conversationID, members) = $0 {
                (conversationID, members)
            } else {
                nil
            }
        }.first
        let (conversationID, members) = try #require(found)
        #expect(conversationID.rawValue == "dm/d-1")
        #expect(Set(members.map(\.displayName)) == Set(["Ada Lovelace", "Grace Hopper"]))
    }

    /// `findings.md` §20.4: one of the four observed conversations - a space
    /// - has no `dm_members` at all. `worldItem(spaceID:roomName:)` leaves
    /// `dm_members` unset the same way, so its `Conversation.members` is
    /// empty and `resolveAndEmitMembers`'s own `guard !ids.isEmpty else {
    /// return }` means nothing should ever be emitted for it.
    @Test func loadConversationsDoesNotEmitMembersChangedForAConversationWithNoMembers() async throws {
        let backend = try backend(apiResponse: apiResponse(items: [
            worldItem(spaceID: "s-1", roomName: "Engineering")
        ]))

        try await backend.connect()
        _ = try await backend.loadConversations()

        let events = await collectEvents(backend)
        #expect(!events.contains {
            if case .membersChanged = $0 {
                true
            } else {
                false
            }
        })
    }

    /// `loadConversations()` must still return promptly and must not fail
    /// because names failed - a name lookup that errors is a degraded
    /// sidebar, not a broken one. Getting this backwards turns a cosmetic
    /// problem into an empty sidebar, which is the bug session 9 already
    /// fixed once for the world call itself.
    @Test func loadConversationsReturnsConversationsEvenWhenMemberResolutionFails() async throws {
        struct Boom: Error {}
        let backend = try backend(
            apiResponse: apiResponse(items: [
                dmWorldItem(dmID: "d-1", memberIDs: ["u-1"])
            ]),
            membersFailure: Boom()
        )
        try await backend.connect()

        let conversations = try await backend.loadConversations()
        #expect(conversations.count == 1)
        #expect(conversations.first?.id.rawValue == "dm/d-1")
    }

    /// The failure above must not vanish silently either - same shape as
    /// `LoadConversationsTests.loadConversationsEmitsABackendErrorCountWhenItemsAreSkipped`,
    /// one layer up.
    ///
    /// Matched on the exact `.transport("the /api/ get_members call: transport
    /// error")` shape - `chatError(fromAPI:call:)` now weaves the failing
    /// call's name into every branch's message, not just `.httpStatus`'s, and
    /// `APIFailure.transport(nil)`'s `safeDescription` is the fixed string
    /// "transport error" (`Boom` classifies as nothing, since only a real
    /// `HTTPTransport` that touches a socket can throw
    /// `ClassifiedTransportFailure`). Matching the whole string, rather than
    /// merely checking it is non-empty, is what keeps this from passing
    /// because of a `.backendError` the channel's own unrelated, concurrent
    /// failure emitted for a different reason (`stream()` throws
    /// `RoutingTransport.NoStream`).
    @Test func loadConversationsEmitsABackendErrorWhenMemberResolutionFails() async throws {
        struct Boom: Error {}
        let backend = try backend(
            apiResponse: apiResponse(items: [
                dmWorldItem(dmID: "d-1", memberIDs: ["u-1"])
            ]),
            membersFailure: Boom()
        )
        try await backend.connect()
        _ = try await backend.loadConversations()

        let events = await collectEvents(backend)
        let found = events.contains {
            guard case let .backendError(error) = $0 else { return false }
            return error == .transport("the /api/ get_members call: transport error")
        }
        #expect(found)
    }
}
