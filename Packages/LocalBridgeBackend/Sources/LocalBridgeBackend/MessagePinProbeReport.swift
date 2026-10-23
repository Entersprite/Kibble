import ChatKit
import Foundation
import GChatBridgeCore
import URLSessionTransport

/// Read-only protocol verification. Reports counts and booleans, never identifiers or content.
public enum MessagePinProbeReport {
    public static func run(
        store: KeychainCredentialStore, expectedSelfID: ChatKit.Member.ID,
        transport: any HTTPTransport = URLSessionTransport(), endpoints: ChatEndpoints = .init()
    ) async -> String {
        var lines = ["message pins read probe"]
        guard let cookies = await APIProbeReport.appendCredential(store: store, lines: &lines),
              let prepared = await APIProbeReport.appendBootstrap(
                  cookies: cookies, store: store, transport: transport, endpoints: endpoints, lines: &lines
              ) else { return lines.joined(separator: "\n") }
        let client = ProtoAPIClient(
            transport: transport, endpoints: endpoints,
            credentials: prepared.credentials, xsrfToken: prepared.wiz.xsrfToken
        )
        do {
            let me = try await client.call(.getSelfUserStatus, GetSelfUserStatusRequest())
            guard me.userStatus.userID.id == expectedSelfID.rawValue else {
                return "Stopped: the saved account identity changed."
            }
            let world = try await client.call(.paginatedWorld, WorldRequestLadder.minimumViable.request)
            for (index, item) in world.worldItems.prefix(20).enumerated() {
                try Task.checkCancellation()
                await append(
                    group: item.groupID,
                    index: index,
                    me: expectedSelfID,
                    client: client,
                    lines: &lines
                )
            }
        } catch {
            lines.append("FAILED: \(APIProbeReport.safeDescription(of: error))")
        }
        return lines.joined(separator: "\n")
    }

    private static func append(
        group: GroupId, index: Int, me: ChatKit.Member.ID,
        client: ProtoAPIClient, lines: inout [String]
    ) async {
        do {
            let details = try await client.call(
                .managementDetails,
                ConversationManagementRequests.details(group)
            )
            let id = ConversationManagementRequests.membershipID(group: group, user: me.rawValue)
            let permissions = try await client.call(
                .managementPermissions,
                ConversationManagementRequests.permissions(id)
            )
            let grant = permissions.capabilities.first { $0.id == id }
                .map { ManagementMapping.grants($0, 59) }
            let response = try await client.call(.listMessages, MessagePinRequests.list(in: group))
            let mapped = response.messages.compactMap(ChannelEventMapping.domainMessage)
            lines.append("group \(index): groupMatches=\(details.hasGroup && details.group.groupID == group) "
                + "unique=\(Set(mapped.map(\.id)).count == mapped.count) "
                + "deleted=\(mapped.count { $0.isDeleted })")
            lines.append("group \(index): joined=\(details.membershipState == .memberJoined) "
                + "permissionMatched=\(grant != nil) canModify=\(grant == true) "
                + "pins=\(response.messages.count) mapped=\(mapped.count) "
                + "scopeMatches=\(response.messages.allSatisfy { $0.id.parentID.topicID.groupID == group }) "
                + "lastPresent=\(response.hasContainsLastMessage) last=\(response.containsLastMessage)")
            if let first = response.messages.first {
                let original = try await client.call(.pinTarget, MessagePinRequests.message(first.id))
                lines.append(
                    "group \(index): originalMatches=\(original.message.id == first.id) "
                        + "originalUserMessage=\(original.message.messageType == .userMessage)"
                )
            }
        } catch {
            lines.append("group \(index) FAILED: \(APIProbeReport.safeDescription(of: error))")
        }
    }
}
