import ChatKit
import Foundation
import GChatBridgeCore
import os

/// One read shared by browsing and diagnostics; owns no credentials, replica or session tasks.
struct SpaceDirectoryReader: Sendable {
    let client: ProtoAPIClient
    var known: [Conversation.ID: Conversation] = [:]
    var check: @Sendable () async throws -> Void = { try Task.checkCancellation() }
    var progress: @Sendable (String) async -> Void = { _ in }

    func discover(
        _ text: String, token: String?, key: String, scope: SpaceDirectoryScope = .discover,
        organization: SpaceDirectoryOrganization = .all
    ) async throws -> SpaceDirectoryPage {
        let membership: ConversationManagementRequests.DirectoryMembership = switch scope {
        case .all: .all
        case .joined: .joined
        default: .notJoined
        }
        let origin: ConversationManagementRequests.DirectoryOrganization = switch organization {
        case .internalOnly: .internalOnly
        case .externalOnly: .externalOnly
        default: .all
        }
        var token = token
        var seen = Set<String>()
        while seen.insert(token ?? "").inserted {
            try await check()
            await report("search started queryLength: \(text.count)")
            let response = try await client.call(
                .searchSpaceDirectory, ConversationManagementRequests.discover(
                    text, token: token, membership: membership, organization: origin
                )
            )
            try await check()
            await report("search returned rows: \(response.spaces.count)")
            let spaces = try await readDetails(response.spaces, scope: scope)
            token = response.nextPageToken.isEmpty ? nil : response.nextPageToken
            if !spaces.isEmpty || token == nil {
                await report("page completed rows: \(spaces.count)")
                return SpaceDirectoryPage(spaces: spaces, nextCursor: token.flatMap {
                    ManagementCursor.encode($0, key: key)
                })
            }
        }
        throw ChatError.decoding("The service repeated a directory page. Try searching again.")
    }

    private func readDetails(
        _ rows: [SearchSpaceDirectoryResponse.Summary],
        scope: SpaceDirectoryScope
    ) async throws
        -> [ConversationDetails] {
        try await withThrowingTaskGroup(of: (Int, ConversationDetails?).self) { group in
            var next = 0
            var results: [(Int, ConversationDetails?)] = []
            for index in 0 ..< min(6, rows.count) {
                group.addTask { try await (index, discovered(rows[index], index: index, scope: scope)) }
                next += 1
            }
            while let result = try await group.next() {
                results.append(result)
                if next < rows.count {
                    let index = next
                    group.addTask { try await (index, discovered(rows[index], index: index, scope: scope)) }
                    next += 1
                }
            }
            return results.sorted { $0.0 < $1.0 }.compactMap(\.1)
        }
    }

    private func discovered(
        _ row: SearchSpaceDirectoryResponse.Summary, index: Int, scope: SpaceDirectoryScope
    ) async throws
        -> ConversationDetails? {
        try await check()
        let membership = ManagementMapping.state(
            row.membershipState, unknown: row.unknownFields.data, field: 6
        )
        guard scope != .discover || membership != .joined,
              scope != .joined || membership == .joined else { return nil }
        await report("detail started index: \(index)")
        guard var details = try await space(row.groupID) else {
            await report("detail excluded index: \(index)")
            return nil
        }
        // Public previews can report invited in details but not a member in the directory.
        if details.membership != .joined, details.membership != .requested, membership != .joined {
            details.membership = membership
        }
        guard scope != .discover || details.membership != .joined,
              scope != .joined || details.membership == .joined else { return nil }
        switch details.membership {
        case .joined, .requested: details.allowedActions = []
        case .invited: details.allowedActions = ["acceptInvitation", "declineInvitation"]
        default: details.allowedActions = ["requestJoin"]
        }
        applyCounts(row, to: &details)
        await report("detail accepted index: \(index)")
        return details
    }

    private func applyCounts(
        _ row: SearchSpaceDirectoryResponse.Summary,
        to details: inout ConversationDetails
    ) {
        if let count = row.memberCounts.counts.first(where: {
            $0.memberType == 1 && $0.membershipState == .memberJoined
        }).flatMap({ nonnegativeCount($0.count) }) {
            details.conversation.memberCount = count
        } else if row.hasMemberCount, row.memberCount >= 0 {
            details.conversation.memberCount = Int(row.memberCount)
        }
        details.linkedGroupCount = row.memberCounts.counts.first(where: {
            $0.memberType == 2 && $0.membershipState == .memberJoined
        }).flatMap { nonnegativeCount($0.count) }
    }

    private func nonnegativeCount(_ value: Int64) -> Int? {
        value >= 0 ? Int(exactly: value) : nil
    }

    private func report(_ stage: String) async {
        SpaceDirectoryLog.event(stage)
        await progress(stage)
    }

    func space(_ group: GroupId) async throws -> ConversationDetails? {
        try await check()
        guard case .spaceID = group.id,
              let id = ChannelEventMapping.conversationID(group) else { return nil }
        let cached = known[id]
        if let cached, cached.kind != .space {
            return nil
        }
        let response = try await client.call(
            .managementDetails,
            ConversationManagementRequests.details(group)
        )
        try await check()
        guard response.hasGroup, response.group.groupID == group else {
            throw ChatError.decoding("The service returned a different space.")
        }
        guard let conversation = ManagementMapping.conversation(response.group, fallback: cached),
              conversation.kind == .space else { return nil }
        let membership = ManagementMapping.state(
            response.membershipState, unknown: response.unknownFields.data, field: 6
        )
        return ManagementMapping.details(
            response,
            conversation: conversation,
            membership: membership,
            actions: []
        )
    }
}

private enum SpaceDirectoryLog {
    static let logger = Logger(subsystem: "com.entersprite.kibble", category: "space-directory")

    static func event(_ stage: String) {
        logger.notice("\(stage, privacy: .public)")
    }
}
