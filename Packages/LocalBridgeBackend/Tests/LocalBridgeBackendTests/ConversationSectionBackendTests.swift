import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

@Suite(.timeLimit(.minutes(1)))
struct ConversationSectionBackendTests {
    @Test func readsOnlyCustomRosterDefinitionsAndMatchesBothLabelFields() async throws {
        let transport = SectionTransport()
        let backend = LocalBridgeBackend(cookies: SearchBackendSupport.cookies, transport: transport)
        try await backend.connect()
        let sections = try #require(try await backend.conversationSections())
        #expect(sections == [
            .init(id: "b", name: "Work", conversationIDs: [Conversation.ID("space/member")], sort: .name),
            .init(id: "a", name: "Later", conversationIDs: [], unreadOnly: true)
        ])
        #expect(await transport.readCount == 1)
        await backend.disconnect()
    }

    @Test func anOmittedRosterIsDistinctFromAPresentRosterWithoutCustomSections() throws {
        var world = PaginatedWorldResponse()
        world.worldSectionResponses = [WorldSectionResponse()]
        #expect(try LocalBridgeBackend.mapConversationSections(world) == nil)

        world.worldSectionResponses[0].rosterSections = [section("built-in", type: 1)]
        #expect(try LocalBridgeBackend.mapConversationSections(world) == [])

        world.worldSectionResponses[0].rosterSections = [section("same"), section("same")]
        #expect(throws: ChatError.self) { try LocalBridgeBackend.mapConversationSections(world) }
    }

    @Test(arguments: SectionWriteTransport.Reply.allCases)
    func sectionEditUsesOneWriteAndRequiresAnAddressedConfirmation(reply: SectionWriteTransport.Reply)
        async throws {
        let transport = SectionWriteTransport(reply: reply)
        let backend = LocalBridgeBackend(cookies: SearchBackendSupport.cookies, transport: transport)
        try await backend.connect()
        let edit = ConversationSectionEdit(id: "section", name: "Renamed", sort: .activity, unreadOnly: false)
        if reply == .addressed || reply == .sparse {
            try await backend.updateConversationSection(edit)
        } else {
            await #expect(throws: ChatError.self) { try await backend.updateConversationSection(edit) }
        }
        #expect(await transport.writes.count == 1)
        #expect(await transport.readCount == (reply == .sparse || reply == .stale ? 2 : 1))
        let write = try #require(await transport.writes.first)
        #expect(write.section.id.id == "section" && write.section.id.label == label("key:section"))
        #expect(write.section.hasUnreadOnly && !write.section.unreadOnly)
        #expect(write.section.contentSort.order == 1 && write.section.activityItemCount == 7)
        #expect(write.updateMask.wholeFields == [3, 4, 10] && !write.updateMask.inverted)
        #expect(write.hasRequestHeader)
        await backend.disconnect()
    }

    @Test func anUnlistedTargetNeverSendsAWrite() async throws {
        let transport = SectionWriteTransport(reply: .addressed)
        let backend = LocalBridgeBackend(cookies: SearchBackendSupport.cookies, transport: transport)
        try await backend.connect()
        let edit = ConversationSectionEdit(id: "missing", name: "New Name")
        await #expect(throws: ChatError.self) { try await backend.updateConversationSection(edit) }
        #expect(await transport.readCount == 1)
        #expect(await transport.writes.isEmpty)
        await backend.disconnect()
    }

    @Test func anUnknownSortTokenIsRejectedBeforeReadingTheRoster() async throws {
        let transport = SectionWriteTransport(reply: .addressed)
        let backend = LocalBridgeBackend(cookies: SearchBackendSupport.cookies, transport: transport)
        try await backend.connect()
        let edit = ConversationSectionEdit(id: "section", sort: SidebarSortOrder(rawValue: "unknown"))
        await #expect(throws: ChatError.self) { try await backend.updateConversationSection(edit) }
        #expect(await transport.readCount == 0)
        #expect(await transport.writes.isEmpty)
        await backend.disconnect()
    }

    @Test(arguments: [SectionLifecycleTransport.Reply.canonicalCreate, .sparseCreate, .existingNameOnly])
    func creationRequiresANewSectionAndAcceptsTheCanonicalID(reply: SectionLifecycleTransport.Reply)
        async throws {
        let transport = SectionLifecycleTransport(reply: reply)
        let backend = LocalBridgeBackend(cookies: SearchBackendSupport.cookies, transport: transport)
        try await backend.connect()
        if reply == .existingNameOnly {
            await #expect(throws: ChatError.self) {
                try await backend.createConversationSection(named: "Work")
            }
        } else {
            let saved = try await backend.createConversationSection(named: "Work")
            #expect(saved == .init(
                id: reply == .canonicalCreate ? "canonical" : "2", name: "Work", conversationIDs: []
            ))
        }
        let writes = await transport.creates
        #expect(writes.count == 1)
        let request = try #require(writes.first)
        #expect(request.section.id.id == "2" && request.section.id.type == 3)
        #expect(request.section.id.label == label("2"))
        #expect(request.section.position == 2 && request.section.contentSort.order == 1)
        #expect(await transport.readCount == (reply == .canonicalCreate ? 1 : 2))
        await backend.disconnect()
    }

    @Test(arguments: [
        SectionLifecycleTransport.Reply.revisionDelete,
        .sparseDelete,
        .staleDelete,
        .omittedDelete
    ])
    func deletionRequiresRevisionOrConfirmedAbsence(reply: SectionLifecycleTransport.Reply) async throws {
        let transport = SectionLifecycleTransport(reply: reply)
        let backend = LocalBridgeBackend(cookies: SearchBackendSupport.cookies, transport: transport)
        try await backend.connect()
        if reply == .revisionDelete || reply == .sparseDelete {
            try await backend.deleteConversationSection("1")
        } else {
            await #expect(throws: ChatError.self) { try await backend.deleteConversationSection("1") }
        }
        let deletes = await transport.deletes
        #expect(deletes.count == 1)
        let request = try #require(deletes.first)
        #expect(request.sectionID.id == "1" && request.sectionID.type == 3)
        #expect(request.sectionID.label == label("key:1"))
        #expect(await transport.readCount == (reply == .revisionDelete ? 1 : 2))
        await backend.disconnect()
    }

    @Test(arguments: ["missing", "built-in"])
    func deletionSendsNoWriteForASectionOutsideTheCustomRoster(id: String) async throws {
        let transport = SectionLifecycleTransport(reply: .revisionDelete)
        let backend = LocalBridgeBackend(cookies: SearchBackendSupport.cookies, transport: transport)
        try await backend.connect()
        try await backend.deleteConversationSection(id)
        #expect(await transport.readCount == 1)
        #expect(await transport.deletes.isEmpty)
        await backend.disconnect()
    }
}

actor SectionLifecycleTransport: HTTPTransport {
    enum Reply: Sendable {
        case canonicalCreate, sparseCreate, existingNameOnly
        case revisionDelete, sparseDelete, staleDelete, omittedDelete
    }

    let reply: Reply
    let base = ActionTransport(kind: .space)
    private(set) var creates: [CreateRosterSectionRequest] = []
    private(set) var deletes: [DeleteRosterSectionRequest] = []
    private(set) var readCount = 0

    init(reply: Reply) {
        self.reply = reply
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard let body = request.body else { return try await base.send(request) }
        switch request.url.lastPathComponent {
        case "create_roster_section":
            #expect(ProtoFieldScan.fields(in: body).fields.map(\.number) == [1, 100])
            return try createResponse(CreateRosterSectionRequest(serializedBytes: body))
        case "delete_roster_section":
            #expect(ProtoFieldScan.fields(in: body).fields.map(\.number) == [2, 100])
            try deletes.append(DeleteRosterSectionRequest(serializedBytes: body))
            var response = DeleteRosterSectionResponse()
            if reply == .revisionDelete {
                response.writeRevision.timestamp = 17
            }
            return try HTTPResponse(status: 200, headers: HTTPHeaders([]), body: response.serializedData())
        case "paginated_world":
            let input = try PaginatedWorldRequest(serializedBytes: body)
            guard input.fetchOptions.contains(.fetchRosterSections) else {
                return try await base.send(request)
            }
            readCount += 1
            return try roster()
        default:
            return try await base.send(request)
        }
    }

    func stream(_ request: HTTPRequest) async throws -> HTTPStream {
        try await base.stream(request)
    }

    private func createResponse(_ request: CreateRosterSectionRequest) throws -> HTTPResponse {
        creates.append(request)
        var response = CreateRosterSectionResponse()
        if reply == .canonicalCreate {
            response.section = request.section
            response.section.id.id = "canonical"
            response.section.id.label = label("canonical-label")
            response.writeRevision.timestamp = 17
        }
        return try HTTPResponse(status: 200, headers: HTTPHeaders([]), body: response.serializedData())
    }

    private func roster() throws -> HTTPResponse {
        var roster = WorldSectionResponse()
        roster.rosterSections = [section("built-in", type: 1), section("1", name: "Work", position: 1)]
        if reply == .sparseCreate, let created = creates.last?.section {
            var row = WorldRosterSection()
            row.definition = created
            roster.rosterSections.append(row)
        }
        if !deletes.isEmpty {
            switch reply {
            case .sparseDelete: roster.rosterSections.removeLast()
            case .omittedDelete: roster.rosterSections.removeAll()
            default: break
            }
        }
        var response = PaginatedWorldResponse()
        response.worldSectionResponses = [roster]
        return try HTTPResponse(status: 200, headers: HTTPHeaders([]), body: response.serializedData())
    }
}

actor SectionWriteTransport: HTTPTransport {
    enum Reply: CaseIterable, Sendable {
        case addressed, sparse, stale, wrongLabel
    }

    let reply: Reply
    private let base = ActionTransport(kind: .space)
    private(set) var writes: [UpdateRosterSectionRequest] = []
    private(set) var readCount = 0

    init(reply: Reply) {
        self.reply = reply
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard let body = request.body else { return try await base.send(request) }
        switch request.url.lastPathComponent {
        case "update_roster_section":
            let write = try UpdateRosterSectionRequest(serializedBytes: body)
            writes.append(write)
            #expect(ProtoFieldScan.fields(in: body).fields.map(\.number) == [1, 3, 100])
            return try response(to: write)
        case "paginated_world":
            let input = try PaginatedWorldRequest(serializedBytes: body)
            guard input.fetchOptions.contains(.fetchRosterSections) else {
                return try await base.send(request)
            }
            readCount += 1
            return try roster()
        default:
            return try await base.send(request)
        }
    }

    func stream(_ request: HTTPRequest) async throws -> HTTPStream {
        try await base.stream(request)
    }

    private func response(to write: UpdateRosterSectionRequest) throws -> HTTPResponse {
        var response = UpdateRosterSectionResponse()
        if reply == .addressed || reply == .wrongLabel {
            response.section = write.section
            response.writeRevision.timestamp = 17
            if reply == .wrongLabel {
                response.section.id.label = label("different-key")
            }
        }
        return try HTTPResponse(status: 200, headers: HTTPHeaders([]), body: response.serializedData())
    }

    private func roster() throws -> HTTPResponse {
        var existing = section("section", name: "Original", position: 1)
        existing.definition.unreadOnly = true
        existing.definition.contentSort.order = 2
        existing.definition.visibleItemCount = 7
        if reply == .sparse, let updated = writes.last?.section {
            existing.definition.name = updated.name
            existing.definition.unreadOnly = updated.unreadOnly
            existing.definition.contentSort = updated.contentSort
        }
        var roster = WorldSectionResponse()
        roster.rosterSections = [existing]
        var response = PaginatedWorldResponse()
        response.worldSectionResponses = [roster]
        return try HTTPResponse(status: 200, headers: HTTPHeaders([]), body: response.serializedData())
    }
}

private actor SectionTransport: HTTPTransport {
    let base = ActionTransport(kind: .space)
    private(set) var readCount = 0

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard request.url.lastPathComponent == "paginated_world", let body = request.body else {
            return try await base.send(request)
        }
        let input = try PaginatedWorldRequest(serializedBytes: body)
        guard input.fetchOptions.contains(.fetchRosterSections) else { return try await base.send(request) }
        readCount += 1
        #expect(ProtoFieldScan.fields(in: body).fields.map(\.number) == [1, 2, 4, 5, 9, 10])
        #expect(input.hasRequestHeader && input.hasRegisterWorldClient && !input.registerWorldClient)
        #expect(input.badgeFetchOptions == [1])
        #expect(input.worldSectionRequests.first?.pageSize == 999)

        var roster = WorldSectionResponse()
        var later = section("a", name: "Later", position: 2)
        later.definition.unreadOnly = true
        var work = section("b", name: "Work", position: 1)
        work.definition.contentSort.order = 2
        roster.rosterSections = [later, section("built-in", type: 1), work]
        var response = PaginatedWorldResponse()
        response.worldSectionResponses = [WorldSectionResponse(), roster]
        response.worldItems = [
            item("member", [label("key:b")]), item("unrelated", [label("key:a", type: 2)]),
            item("ambiguous", [label("key:a"), label("key:b")])
        ]
        return try HTTPResponse(status: 200, headers: HTTPHeaders([]), body: response.serializedData())
    }

    func stream(_ request: HTTPRequest) async throws -> HTTPStream {
        try await base.stream(request)
    }

    private func item(_ id: String, _ labels: [GroupLabel]) -> WorldItemLite {
        var item = WorldItemLite()
        item.groupID = WorldItemFixture.spaceGroupID(id)
        item.readState.groupLabels = labels
        return item
    }
}

private func section(
    _ id: String,
    name: String = "Section",
    type: Int32 = 3,
    position: Int32 = 0
) -> WorldRosterSection {
    var section = WorldRosterSection()
    section.definition.id.type = type
    section.definition.id.id = id
    section.definition.id.label = label("key:" + id)
    section.definition.name = name
    section.definition.position = position
    return section
}

private func label(_ key: String, type: Int32 = 4) -> GroupLabel {
    var label = GroupLabel()
    label.type = type
    label.secondaryKey = key
    return label
}
