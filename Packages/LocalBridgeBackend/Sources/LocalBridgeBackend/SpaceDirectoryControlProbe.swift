import ChatKit
import Foundation
import GChatBridgeCore
import os

/// Read-only controls. Reports only filter labels and aggregate response counts.
enum SpaceDirectoryControlProbe {
    static func run(
        client: ProtoAPIClient, query: String, known: [Conversation.ID: Conversation]
    ) async -> [String] {
        let memberships: [ConversationManagementRequests.DirectoryMembership] = [.all, .joined, .notJoined]
        let organizations: [ConversationManagementRequests.DirectoryOrganization] = [
            .all, .internalOnly, .externalOnly
        ]
        var lines: [String] = []
        for membership in memberships {
            for organization in organizations {
                do {
                    let response = try await client.call(
                        .searchSpaceDirectory,
                        ConversationManagementRequests.discover(
                            query,
                            token: nil,
                            membership: membership,
                            organization: organization
                        )
                    )
                    let joined = response.spaces.filter { $0.membershipState == .memberJoined }.count
                    let label = "control \(membership)/\(organization)"
                    lines.append("\(label): rows \(response.spaces.count), joined \(joined)")
                } catch {
                    let failure = APIProbeReport.safeDescription(of: error)
                    lines.append("control \(membership)/\(organization) failed: \(failure)")
                }
            }
        }
        do {
            let response = try await client.call(
                .listInvitedRooms,
                ConversationManagementRequests.invitations(spam: true)
            )
            lines.append("control spam: rows \(response.invitations.count)")
        } catch {
            lines.append("control spam failed: \(APIProbeReport.safeDescription(of: error))")
        }
        lines += await checkedPages(client: client, query: query, known: known)
        let logger = Logger(subsystem: "com.entersprite.kibble", category: "space-directory")
        for line in lines {
            logger.notice("\(line, privacy: .public)")
        }
        return lines
    }

    private static func checkedPages(
        client: ProtoAPIClient, query: String, known: [Conversation.ID: Conversation]
    ) async -> [String] {
        let reader = SpaceDirectoryReader(client: client, known: known)
        var lines: [String] = []
        for scope in [SpaceDirectoryScope.all, .joined] {
            do {
                let page = try await reader.discover(query, token: nil, key: "control", scope: scope)
                let counts = page.spaces.filter { $0.conversation.memberCount != nil }.count
                lines.append("checked \(scope.type): rows \(page.spaces.count), with member counts \(counts)")
            } catch {
                lines.append("checked \(scope.type) failed: \(APIProbeReport.safeDescription(of: error))")
            }
        }
        return lines
    }
}
