import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

@Suite(.timeLimit(.minutes(1)))
struct ConversationSectionPlacementTests {
    @Test(arguments: [PlacementTransport.Mode.add, .move, .retainPrevious, .remove, .resume, .alreadyPlaced])
    func sendsOnlyTheNeededLabelsAndReadsTheExactConversation(mode: PlacementTransport.Mode) async throws {
        let transport = PlacementTransport(mode: mode)
        let backend = LocalBridgeBackend(cookies: SearchBackendSupport.cookies, transport: transport)
        try await backend.connect()
        try await backend.moveConversationToSection(.init(
            conversationID: .init("space/a"), sectionID: mode == .remove ? nil : "destination"
        ))
        let expected: [PlacementTransport.Operation] = switch mode {
        case .add, .move: [.read, .apply("label-new"), .read]
        case .retainPrevious: [.read, .apply("label-new"), .read, .remove("label-old"), .read]
        case .remove, .resume: [.read, .remove("label-old"), .read]
        default: [.read]
        }
        #expect(await transport.operations == expected)
        #expect(await transport.customKeys == (mode == .remove ? [] : ["label-new"]))
        await backend.disconnect()
    }

    @Test(arguments: [
        PlacementTransport.Mode.staleAfterApply,
        .concurrentlyRelabeled,
        .foreignConversation,
        .omittedReadState,
        .unknownCustomLabel,
        .unjoined
    ])
    func refusesUnconfirmedMovesWithoutRemovingTheOriginalLabel(mode: PlacementTransport.Mode) async throws {
        let transport = PlacementTransport(mode: mode)
        let backend = LocalBridgeBackend(cookies: SearchBackendSupport.cookies, transport: transport)
        try await backend.connect()
        await #expect(throws: ChatError.self) {
            try await backend.moveConversationToSection(.init(
                conversationID: .init("space/a"),
                sectionID: "destination"
            ))
        }
        let expected: [PlacementTransport.Operation] = mode == .staleAfterApply || mode ==
            .concurrentlyRelabeled ?
            [.read, .apply("label-new"), .read] : [.read]
        #expect(await transport.operations == expected)
        await backend.disconnect()
    }

    @Test func aRevisionAloneDoesNotConfirmRemovalFromASection() async throws {
        let transport = PlacementTransport(mode: .ambiguousRemoval)
        let backend = LocalBridgeBackend(cookies: SearchBackendSupport.cookies, transport: transport)
        try await backend.connect()
        await #expect(throws: ChatError.self) {
            try await backend.moveConversationToSection(.init(
                conversationID: .init("space/a"),
                sectionID: nil
            ))
        }
        #expect(await transport.operations == [.read, .remove("label-old"), .read])
        await backend.disconnect()
    }
}

actor PlacementTransport: HTTPTransport {
    enum Mode: Sendable {
        case add, move, retainPrevious, remove, resume, alreadyPlaced
        case staleAfterApply, foreignConversation, omittedReadState, unknownCustomLabel, unjoined
        case concurrentlyRelabeled, ambiguousRemoval
    }

    enum Operation: Equatable, Sendable {
        case read
        case apply(String)
        case remove(String)
    }

    let mode: Mode
    let base = ActionTransport(kind: .space)
    let group = WorldItemFixture.spaceGroupID("a")
    private(set) var operations: [Operation] = []
    private(set) var customKeys: Set<String>

    init(mode: Mode) {
        self.mode = mode
        customKeys = switch mode {
        case .add: []
        case .alreadyPlaced: ["label-new"]
        case .resume: ["label-old", "label-new"]
        case .unknownCustomLabel: ["unknown-label"]
        default: ["label-old"]
        }
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard let body = request.body else { return try await base.send(request) }
        switch request.url.lastPathComponent {
        case "paginated_world":
            let input = try PaginatedWorldRequest(serializedBytes: body)
            guard input.fetchOptions.contains(.fetchRosterSections)
            else { return try await base.send(request) }
            var roster = WorldSectionResponse()
            roster.rosterSections = [
                section("original", key: "label-old"),
                section("destination", key: "label-new"),
                section("other", key: "label-other")
            ]
            var response = PaginatedWorldResponse()
            response.worldSectionResponses = [roster]
            return try ok(response.serializedData())
        case "get_group":
            let input = try GetGroupRequest(serializedBytes: body)
            #expect(input.groupID == group)
            operations.append(.read)
            return try readGroup()
        case "apply_group_label", "remove_group_label":
            return try changeLabel(body, apply: request.url.lastPathComponent == "apply_group_label")
        default:
            return try await base.send(request)
        }
    }

    func stream(_ request: HTTPRequest) async throws -> HTTPStream {
        try await base.stream(request)
    }

    private func changeLabel(_ body: Data, apply: Bool) throws -> HTTPResponse {
        let input = try ChangeGroupLabelRequest(serializedBytes: body)
        #expect(ProtoFieldScan.fields(in: body).fields.map(\.number) == [1, 2, 100])
        #expect(input.groupID == group && input.label.type == 4 && input.hasRequestHeader)
        let key = input.label.secondaryKey
        operations.append(apply ? .apply(key) : .remove(key))
        if apply {
            if mode == .move || mode == .add {
                customKeys = [key]
            }
            if mode == .retainPrevious {
                customKeys.insert(key)
            }
            if mode == .concurrentlyRelabeled {
                customKeys = [key, "label-other"]
            }
        } else if mode != .ambiguousRemoval {
            customKeys.remove(key)
        }
        var response = ChangeGroupLabelResponse()
        response.writeRevision.timestamp = 17
        return try ok(response.serializedData())
    }

    private func readGroup() throws -> HTTPResponse {
        var response = GetGroupResponse()
        response.group.groupID = mode == .foreignConversation ? WorldItemFixture.spaceGroupID("other") : group
        response.membershipState = mode == .unjoined ? .memberInvited : .memberJoined
        if mode != .omittedReadState {
            response.group.groupReadState.id.groupID = group
            // An unrelated label may share a secondary key with a custom section.
            response.group.groupReadState.groupLabels = customKeys.sorted().map { label($0) }
                + [label("label-old", type: 2)]
        }
        return try ok(response.serializedData())
    }

    private func section(_ id: String, key: String) -> WorldRosterSection {
        var row = WorldRosterSection()
        row.definition.id.type = 3
        row.definition.id.id = id
        row.definition.id.label = label(key)
        row.definition.name = id
        return row
    }

    private func label(_ key: String, type: Int32 = 4) -> GroupLabel {
        var label = GroupLabel()
        label.type = type
        label.secondaryKey = key
        return label
    }

    private func ok(_ body: Data) -> HTTPResponse {
        HTTPResponse(status: 200, headers: HTTPHeaders([]), body: body)
    }
}
