import ChatKit
import GChatBridgeCore

public extension LocalBridgeBackend {
    func moveConversationToSection(_ placement: ConversationSectionPlacement) async throws {
        guard placement.isValid, let group = ChannelEventMapping.groupID(for: placement.conversationID) else {
            throw ChatError.unknown("This conversation cannot be moved to a section.")
        }
        try await withConversationSectionWrite { client, generation in
            let world = try await readConversationSectionWorld(using: client, generation: generation)
            guard let definitions = try Self.customSectionDefinitions(world) else {
                throw ChatError.unknown("This section list is unavailable.")
            }
            let destination = definitions.first { $0.id.id == placement.sectionID }?.id.label
            guard placement.sectionID == nil || destination != nil else {
                throw ChatError.unknown("This section is no longer available.")
            }
            let labels = Dictionary(uniqueKeysWithValues: definitions.map { (
                $0.id.label.secondaryKey,
                $0.id.label
            ) })
            let changed = try await saveSectionPlacement(
                destination, in: group, labels: labels, client: client, generation: generation
            )
            try checkManagementGeneration(generation)
            if changed {
                guard await emitCommitted(.conversationSectionsChanged(conversationID: placement
                        .conversationID))
                else { throw CancellationError() }
                try checkManagementGeneration(generation)
            }
        }
    }
}

extension LocalBridgeBackend {
    private func saveSectionPlacement(
        _ destination: GroupLabel?, in group: GroupId, labels: [String: GroupLabel],
        client: ProtoAPIClient, generation: Int
    ) async throws -> Bool {
        let desired = Set(destination.map { [$0.secondaryKey] } ?? [])
        let before = try await readSectionLabels(
            in: group,
            known: labels,
            client: client,
            generation: generation
        )
        if before == desired {
            return false
        }
        let previous = before.subtracting(desired)
        guard previous.count <= 1 else {
            throw ChatError.unknown("This conversation has conflicting section labels.")
        }
        var current = before
        if let destination, !before.contains(destination.secondaryKey) {
            try checkManagementGeneration(generation)
            _ = try await client.call(
                .applyGroupLabel,
                ConversationSectionRequests.changeLabel(destination, in: group)
            )
            current = try await readSectionLabels(
                in: group,
                known: labels,
                client: client,
                generation: generation
            )
        }
        if current != desired {
            let failure = ChatError.unknown("Google Chat did not confirm the section move.")
            guard current == desired.union(previous), let key = previous.first, let label = labels[key] else {
                throw failure
            }
            try checkManagementGeneration(generation)
            _ = try await client.call(
                .removeGroupLabel,
                ConversationSectionRequests.changeLabel(label, in: group)
            )
            let after = try await readSectionLabels(
                in: group,
                known: labels,
                client: client,
                generation: generation
            )
            guard after == desired else { throw failure }
        }
        return true
    }

    private func readSectionLabels(
        in group: GroupId, known labels: [String: GroupLabel], client: ProtoAPIClient, generation: Int
    ) async throws -> Set<String> {
        let response = try await readAddressedManagementGroup(group, client: client, generation: generation)
        let state = response.group.groupReadState
        guard response.membershipState == .memberJoined, response.group.hasGroupReadState,
              !state.id.hasGroupID || state.id.groupID == group, state.groupLabels.count <= 200 else {
            throw ChatError.decoding("Google Chat did not return this conversation’s section labels.")
        }
        var current = Set<String>()
        for label in state.groupLabels where label.type == 4 {
            guard let key = ConversationSectionRequests.customLabelKey(label), labels[key] != nil else {
                throw ChatError.unknown("This conversation has a section label outside the current list.")
            }
            current.insert(key)
        }
        return current
    }
}
