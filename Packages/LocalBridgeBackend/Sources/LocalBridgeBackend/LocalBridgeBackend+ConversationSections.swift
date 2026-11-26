import ChatKit
import Foundation
import GChatBridgeCore

public extension LocalBridgeBackend {
    func conversationSections() async throws -> [ConversationSection]? {
        guard let apiClient, isConnected else { throw ChatError.notAuthenticated }
        return try await Self.mapConversationSections(
            readConversationSectionWorld(using: apiClient, generation: directoryGeneration)
        )
    }

    func updateConversationSection(_ edit: ConversationSectionEdit) async throws {
        guard edit.isValid else { throw ChatError.unknown("Enter a valid section change.") }
        try await withConversationSectionWrite { client, generation in
            try await saveConversationSection(edit, using: client, generation: generation)
        }
    }

    func createConversationSection(named name: String) async throws -> ConversationSection {
        guard ConversationSection.isValidName(name) else {
            throw ChatError.unknown("Enter a valid section name.")
        }
        return try await withConversationSectionWrite { client, generation in
            try await createSection(named: name, using: client, generation: generation)
        }
    }

    func deleteConversationSection(_ id: String) async throws {
        guard ConversationSection.isValidID(id) else {
            throw ChatError.unknown("This section is no longer available.")
        }
        try await withConversationSectionWrite { client, generation in
            try await deleteSection(id, using: client, generation: generation)
        }
    }

    internal func withConversationSectionWrite<Value>(
        _ perform: (ProtoAPIClient, Int) async throws -> Value
    ) async throws -> Value {
        guard let apiClient, isConnected else { throw ChatError.notAuthenticated }
        guard conversationSectionWriteID == nil else {
            throw ChatError.unknown("A section change is already in progress.")
        }
        let writeID = UUID()
        let generation = directoryGeneration
        conversationSectionWriteID = writeID
        defer {
            if conversationSectionWriteID == writeID {
                conversationSectionWriteID = nil
            }
        }
        do {
            return try await perform(apiClient, generation)
        } catch let error as APIFailure {
            throw Self.chatError(fromAPI: error, call: "conversation section")
        }
    }
}

extension LocalBridgeBackend {
    static func mapConversationSections(_ response: PaginatedWorldResponse) throws -> [ConversationSection]? {
        guard let custom = try customSectionDefinitions(response) else { return nil }
        let labels = Set(custom.map(\.id.label.secondaryKey))
        var membership: [String: Set<Conversation.ID>] = [:]
        for item in response.worldItems {
            guard let id = ChannelEventMapping.conversationID(item.groupID) else { continue }
            // The sidebar shows one placement per conversation. A conflicting set of
            // labels still leaves the conversation available under its default kind.
            let matching = Set(item.readState.groupLabels
                .compactMap(ConversationSectionRequests.customLabelKey))
                .intersection(labels)
            if matching.count == 1, let key = matching.first {
                membership[key, default: []].insert(id)
            }
        }
        return custom.sorted { $0.position < $1.position }.map { definition in
            section(from: definition, members: membership[definition.id.label.secondaryKey, default: []])
        }
    }

    private static func section(
        from definition: RosterSectionDefinition, members: Set<Conversation.ID> = []
    ) -> ConversationSection {
        ConversationSection(
            id: definition.id.id, name: definition.name, conversationIDs: members,
            sort: definition.contentSort.order == 2 ? .name : .activity, unreadOnly: definition.unreadOnly
        )
    }

    static func customSectionDefinitions(_ response: PaginatedWorldResponse) throws
        -> [RosterSectionDefinition]? {
        guard let roster = try rosterDefinitions(response) else { return nil }
        return try customSectionDefinitions(in: roster)
    }

    private static func rosterDefinitions(_ response: PaginatedWorldResponse) throws
        -> [RosterSectionDefinition]? {
        guard let roster = response.worldSectionResponses.first(where: { !$0.rosterSections.isEmpty })?
            .rosterSections else { return nil }
        guard roster.count <= 200, roster.allSatisfy({ $0.hasDefinition && $0.definition.id.hasType }) else {
            throw ChatError.decoding("The conversation section list is incomplete.")
        }
        return roster.map(\.definition)
    }

    private static func customSectionDefinitions(in roster: [RosterSectionDefinition]) throws
        -> [RosterSectionDefinition] {
        let custom = roster.filter { $0.id.type == 3 }
        var ids = Set<String>()
        var labels = Set<String>()
        for definition in custom {
            guard let id = ConversationSectionRequests.customSectionID(definition.id),
                  ConversationSection.isValidID(definition.name),
                  let key = ConversationSectionRequests.customLabelKey(definition.id.label),
                  ids.insert(id).inserted, labels.insert(key).inserted else {
                throw ChatError.decoding("The service returned an invalid conversation section.")
            }
        }
        return custom
    }
}

extension LocalBridgeBackend {
    private func createSection(
        named name: String, using client: ProtoAPIClient, generation: Int
    ) async throws -> ConversationSection {
        let before = try await readConversationSectionWorld(using: client, generation: generation)
        guard let roster = try Self.rosterDefinitions(before), roster.count < 200 else {
            throw ChatError.unknown("Unable to add a section to this list.")
        }
        _ = try Self.customSectionDefinitions(in: roster)
        let existingIDs = Set(roster.map(\.id.id))
        let existingLabels = Set(roster
            .compactMap { ConversationSectionRequests.customLabelKey($0.id.label) })
        let temporaryID = nextSectionIdentity(avoiding: existingIDs.union(existingLabels))
        let request = ConversationSectionRequests.create(
            name: name, temporaryID: temporaryID, position: Int32(roster.count)
        )
        try checkManagementGeneration(generation)
        let response = try await client.call(.createRosterSection, request)
        try checkManagementGeneration(generation)
        let saved = try await confirmCreatedSection(
            request.section, response: response, existing: (existingIDs, existingLabels),
            using: client, generation: generation
        )
        guard await emitCommitted(.conversationSectionsChanged()) else { throw CancellationError() }
        try checkManagementGeneration(generation)
        return Self.section(from: saved)
    }

    private func nextSectionIdentity(avoiding used: Set<String>) -> String {
        while used.contains(String(nextTemporaryConversationSectionID)) {
            nextTemporaryConversationSectionID += 1
        }
        defer { nextTemporaryConversationSectionID += 1 }
        return String(nextTemporaryConversationSectionID)
    }

    private func confirmCreatedSection(
        _ sent: RosterSectionDefinition, response: CreateRosterSectionResponse,
        existing: (ids: Set<String>, labels: Set<String>), using client: ProtoAPIClient, generation: Int
    ) async throws -> RosterSectionDefinition {
        let echoed = response.section
        if response.writeRevision.timestamp > 0, echoed.name == sent.name,
           let id = ConversationSectionRequests.customSectionID(echoed.id), !existing.ids.contains(id),
           let label = ConversationSectionRequests.customLabelKey(echoed.id.label),
           !existing.labels.contains(label) {
            return echoed
        }
        let after = try await readConversationSectionWorld(using: client, generation: generation)
        guard let saved = try Self.customSectionDefinitions(after)?.first(where: {
            Self.isSameSectionID($0.id, sent.id)
        }), saved.name == sent.name else {
            throw ChatError.unknown("Google Chat did not confirm the new section.")
        }
        return saved
    }

    private func deleteSection(_ id: String, using client: ProtoAPIClient, generation: Int) async throws {
        let before = try await readConversationSectionWorld(using: client, generation: generation)
        guard let roster = try Self.customSectionDefinitions(before) else {
            throw ChatError.unknown("This section list is unavailable.")
        }
        guard let current = roster.first(where: { $0.id.id == id }) else { return }
        try checkManagementGeneration(generation)
        let response = try await client.call(
            .deleteRosterSection,
            ConversationSectionRequests.delete(current.id)
        )
        try checkManagementGeneration(generation)
        if response.writeRevision.timestamp <= 0 {
            let after = try await readConversationSectionWorld(using: client, generation: generation)
            let label = current.id.label.secondaryKey
            guard let remaining = try Self.customSectionDefinitions(after),
                  !remaining.contains(where: { $0.id.id == id || $0.id.label.secondaryKey == label })
            else {
                throw ChatError.unknown("Google Chat did not confirm the section deletion.")
            }
        }
        guard await emitCommitted(.conversationSectionsChanged(removedSectionID: id)) else {
            throw CancellationError()
        }
        try checkManagementGeneration(generation)
    }

    func readConversationSectionWorld(using client: ProtoAPIClient, generation: Int) async throws
        -> PaginatedWorldResponse {
        try checkManagementGeneration(generation)
        let response: PaginatedWorldResponse
        do {
            response = try await client.call(.paginatedWorld, ConversationSectionRequests.list())
        } catch {
            throw Self.chatError(fromAPI: error)
        }
        try checkManagementGeneration(generation)
        return response
    }

    private func saveConversationSection(
        _ edit: ConversationSectionEdit, using client: ProtoAPIClient, generation: Int
    ) async throws {
        let before = try await readConversationSectionWorld(using: client, generation: generation)
        guard let current = try Self.customSectionDefinitions(before)?.first(where: { $0.id.id == edit.id })
        else { throw ChatError.unknown("This section is no longer available.") }
        if Self.matchesSectionEdit(edit, in: current, requirePresence: false) {
            return
        }
        let request = ConversationSectionRequests.update(
            current, name: edit.name, unreadOnly: edit.unreadOnly, sort: edit.sort.map { $0 == .name ? 2 : 1 }
        )
        try checkManagementGeneration(generation)
        let response = try await client.call(.updateRosterSection, request)
        try checkManagementGeneration(generation)
        try await confirmConversationSectionEdit(
            edit,
            response: response,
            currentID: current.id,
            using: client,
            generation: generation
        )
        guard await emitCommitted(.conversationSectionsChanged()) else { throw CancellationError() }
        try checkManagementGeneration(generation)
    }

    private func confirmConversationSectionEdit(
        _ edit: ConversationSectionEdit, response: UpdateRosterSectionResponse, currentID: RosterSectionID,
        using client: ProtoAPIClient, generation: Int
    ) async throws {
        let echoedID = response.section.id
        let failure = ChatError.unknown("Google Chat did not confirm the section change.")
        guard !Self.conflictsWithSectionID(echoedID, expected: currentID) else { throw failure }
        if Self.isSameSectionID(echoedID, currentID), response.writeRevision.timestamp > 0,
           Self.matchesSectionEdit(edit, in: response.section, requirePresence: true) {
            return
        }
        let after = try await readConversationSectionWorld(using: client, generation: generation)
        guard let saved = try Self.customSectionDefinitions(after)?.first(where: {
            Self.isSameSectionID($0.id, currentID)
        }), Self.matchesSectionEdit(edit, in: saved, requirePresence: false) else { throw failure }
    }

    private static func isSameSectionID(_ id: RosterSectionID, _ expected: RosterSectionID) -> Bool {
        id.id == expected.id && id.type == expected.type
            && id.label.type == expected.label.type && id.label.secondaryKey == expected.label.secondaryKey
    }

    private static func conflictsWithSectionID(_ id: RosterSectionID, expected: RosterSectionID) -> Bool {
        (id.hasID && id.id != expected.id) || (id.hasType && id.type != expected.type)
            || (id.label.hasType && id.label.type != expected.label.type)
            || (id.label.hasSecondaryKey && id.label.secondaryKey != expected.label.secondaryKey)
    }

    private static func matchesSectionEdit(
        _ edit: ConversationSectionEdit, in definition: RosterSectionDefinition, requirePresence: Bool
    ) -> Bool {
        if let name = edit.name, name != definition.name {
            return false
        }
        if let unread = edit.unreadOnly,
           unread != definition.unreadOnly || (requirePresence && !definition.hasUnreadOnly) {
            return false
        }
        guard let sort = edit.sort else { return true }
        if requirePresence {
            return definition.contentSort.order == (sort == .name ? 2 : 1)
        }
        return sort == (definition.contentSort.order == 2 ? .name : .activity)
    }
}
