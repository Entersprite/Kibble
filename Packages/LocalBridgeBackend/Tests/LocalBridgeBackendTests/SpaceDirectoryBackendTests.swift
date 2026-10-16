import ChatKit
import Foundation
import GChatBridgeCore
import SwiftProtobuf
import Testing
@testable import LocalBridgeBackend

private actor SpaceDirectoryTransport: HTTPTransport {
    let base = ActionTransport(kind: .space)
    let joinedState: MembershipState
    private(set) var searches: [SearchSpaceDirectoryRequest] = []
    private(set) var methods: [String] = []
    private(set) var invitations: [ListInvitedRoomsRequest] = []

    init(joinedState: MembershipState = .memberJoined) {
        self.joinedState = joinedState
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        methods.append(request.url.lastPathComponent)
        switch request.url.lastPathComponent {
        case "search_space_directory": return try search(request)
        case "get_group": return try metadata(request)
        case "list_invited_rooms":
            let input = try ListInvitedRoomsRequest(serializedBytes: request.body ?? Data())
            invitations.append(input)
            var response = ListInvitedRoomsResponse()
            response.invitations = (input.inviteCategory == .spamInvite ? ["spam"] : ["invited", "meet"])
                .map { id in
                    var row = ListInvitedRoomsResponse.Invitation()
                    row.name = id; row.groupID.spaceID.spaceID = id
                    return row
                }
            return try ok(response)
        default: return try await base.send(request)
        }
    }

    private func search(_ request: HTTPRequest) throws -> HTTPResponse {
        let input = try SearchSpaceDirectoryRequest(serializedBytes: request.body ?? Data())
        searches.append(input)
        var response = SearchSpaceDirectoryResponse()
        if input.filter.membership.criteria.isEmpty {
            response.spaces = [
                summary("joined", .memberJoined),
                summary("available", .memberNotAMember),
                summary("meet", .memberJoined)
            ]
            return try ok(response)
        }
        if input.filter.membership.criteria.first?.type == 1 {
            response.spaces = [summary("joined", .memberJoined), summary("meet", .memberJoined)]
            return try ok(response)
        }
        if input.pageToken.isEmpty {
            response.spaces = [summary("joined", .memberJoined), summary("meet", .memberNotAMember)]
            // Source wire token is field1; independent of the generated field declaration.
            let bytes = try response.serializedData() + Data([0x0A, 4, 110, 101, 120, 116])
            return HTTPResponse(status: 200, headers: HTTPHeaders([]), body: bytes)
        } else {
            response.spaces = [
                summary("available", .memberNotAMember),
                summary("stale", .memberNotAMember)
            ]
            response.nextPageToken = "more"
        }
        return try ok(response)
    }

    private func metadata(_ request: HTTPRequest) throws -> HTTPResponse {
        let input = try GetGroupRequest(serializedBytes: request.body ?? Data())
        var response = GetGroupResponse()
        if input.groupID.spaceID.spaceID == "meet" {
            response.group = try Group(serializedBytes: Data([0x88, 0x02, 0x0A]))
        } else {
            response.group.attributeCheckerGroupType = .flatRoom
        }
        response.group.groupID = input.groupID
        response.group.name = input.groupID.spaceID.spaceID
        switch input.groupID.spaceID.spaceID {
        case "stale": response.membershipState = .memberJoined
        case "joined": response.membershipState = joinedState
        // Live directory summaries report3 while scoped public preview metadata reports1.
        case "invited", "available", "spam": response.membershipState = .memberInvited
        default: response.membershipState = .memberNotAMember
        }
        return try ok(response)
    }

    func stream(_ request: HTTPRequest) async throws -> HTTPStream {
        try await base.stream(request)
    }

    private func summary(_ id: String, _ state: MembershipState) -> SearchSpaceDirectoryResponse.Summary {
        var row = SearchSpaceDirectoryResponse.Summary()
        row.groupID.spaceID.spaceID = id; row.name = id; row.membershipState = state
        if id == "available" {
            row.memberCounts.counts = [(1, 7), (2, 1)].map { type, count in
                var entry = SearchSpaceDirectoryResponse.Count()
                entry.memberType = Int32(type); entry.count = Int64(count); entry
                    .membershipState = .memberJoined
                return entry
            }
        }
        return row
    }

    private func ok(_ value: some SwiftProtobuf.Message) throws -> HTTPResponse {
        try HTTPResponse(status: 200, headers: HTTPHeaders([]), body: value.serializedData())
    }
}

@Suite(.timeLimit(.minutes(1)))
struct SpaceDirectoryBackendTests {
    @Test func aStaleJoinedSummaryCannotOverrideFreshUnjoinedMetadata() async throws {
        let transport = SpaceDirectoryTransport(joinedState: .memberInvited)
        let backend = LocalBridgeBackend(cookies: SearchBackendSupport.cookies, transport: transport)
        try await backend.connect()
        try await SearchBackendSupport.waitForSelf(backend)
        let joined = try await backend.browseSpaces(.init(scope: .joined), after: nil)
        #expect(joined.spaces.isEmpty)
        let all = try await backend.browseSpaces(.init(scope: .all), after: nil)
        #expect(all.spaces.first { $0.conversation.id == .init("space/joined") }?.membership == .invited)
        await backend.disconnect()
    }

    @Test func allAndJoinedUseTheSameDirectoryAndExcludeMeetingChats() async throws {
        let transport = SpaceDirectoryTransport()
        let backend = LocalBridgeBackend(cookies: SearchBackendSupport.cookies, transport: transport)
        try await backend.connect()
        try await SearchBackendSupport.waitForSelf(backend)
        let all = try await backend.browseSpaces(.init(scope: .all, organization: .externalOnly), after: nil)
        #expect(all.spaces.map(\.conversation.id) == [.init("space/joined"), .init("space/available")])
        #expect(all.spaces.first?.membership == .joined)
        let available = try #require(all.spaces.last)
        #expect(available.conversation.memberCount == 7 && available.linkedGroupCount == 1)
        let joined = try await backend.browseSpaces(.init(scope: .joined), after: nil)
        #expect(joined.spaces.map(\.conversation.id) == [.init("space/joined")])
        let requests = await transport.searches
        #expect(requests.first?.filter.organization == 1)
        #expect(requests.last?.filter.membership.criteria.first?.type == 1)
        await backend.disconnect()
    }

    @Test func spamUsesItsOwnInvitationCategory() async throws {
        let transport = SpaceDirectoryTransport()
        let backend = LocalBridgeBackend(cookies: SearchBackendSupport.cookies, transport: transport)
        try await backend.connect()
        try await SearchBackendSupport.waitForSelf(backend)
        let spam = try await backend.browseSpaces(.init(scope: .spamInvitations), after: nil)
        #expect(spam.spaces.map(\.conversation.id) == [.init("space/spam")])
        #expect(await transport.invitations.first?.inviteCategory == .spamInvite)
        #expect(await transport.searches.isEmpty)
        await backend.disconnect()
    }

    @Test func directoryCursorCannotCrossOrganizationFilters() async throws {
        let transport = SpaceDirectoryTransport()
        let backend = LocalBridgeBackend(cookies: SearchBackendSupport.cookies, transport: transport)
        try await backend.connect()
        try await SearchBackendSupport.waitForSelf(backend)
        let first = try await backend.browseSpaces(.init(), after: nil)
        let cursor = try #require(first.nextCursor)
        await #expect(throws: ChatError.self) {
            _ = try await backend.browseSpaces(.init(organization: .externalOnly), after: cursor)
        }
        #expect(await transport.searches.count == 2)
        await backend.disconnect()
    }

    @Test func diagnosticIsBoundedReadOnlyAndDoesNotPrintAccountValues() async {
        let transport = SpaceDirectoryTransport()
        let client = ProtoAPIClient(
            transport: transport, endpoints: ChatEndpoints(),
            credentials: SessionCredentials(SearchBackendSupport.cookies), xsrfToken: nil
        )
        let lines = await SpaceDirectoryProbeReport.inspect(client: client, query: "private-query-sentinel")
        let report = lines.joined(separator: "\n")
        #expect(!report.contains("private-query-sentinel"))
        #expect(!report.contains("joined"))
        #expect(!report.contains("meet"))
        #expect(report.contains("empty-query pipeline returned rows: 1"))
        #expect(report.contains("typed-query pipeline returned rows: 1"))
        let methods = await transport.methods
        #expect(Set(methods) == ["search_space_directory", "get_group"])
        #expect(report.contains("partial-query pipeline returned rows: 1"))
        #expect(methods.count == 15)
    }

    @Test func discoverySkipsJoinedAndMeetChatsAndContinuesPastAnEntireFilteredPage() async throws {
        let transport = SpaceDirectoryTransport()
        let backend = LocalBridgeBackend(cookies: SearchBackendSupport.cookies, transport: transport)
        try await backend.connect()
        try await SearchBackendSupport.waitForSelf(backend)
        let result = try await backend.browseSpaces(.init(scope: .discover, text: "query"), after: nil)
        #expect(result.spaces.map(\.conversation.id) == [.init("space/available")])
        #expect(result.spaces.first?.membership == ParticipantState("provider:3"))
        #expect(result.spaces.first?.allowedActions == ["requestJoin"])
        #expect(result.spaces.allSatisfy { $0.conversation.kind == .space && $0.membership != .joined })
        let requests = await transport.searches
        #expect(requests.map(\.query) == ["query", "query"])
        #expect(requests.map(\.pageToken) == ["", "next"])
        await backend.disconnect()
    }

    @Test func invitationsContainOnlyActualInvitedSpaces() async throws {
        let transport = SpaceDirectoryTransport()
        let backend = LocalBridgeBackend(cookies: SearchBackendSupport.cookies, transport: transport)
        try await backend.connect()
        try await SearchBackendSupport.waitForSelf(backend)
        let result = try await backend.browseSpaces(.init(scope: .invitations), after: nil)
        #expect(result.spaces.map(\.conversation.id) == [.init("space/invited")])
        #expect(result.spaces.first?.membership == .invited)
        #expect(await transport.searches.isEmpty)
        await backend.disconnect()
    }
}
