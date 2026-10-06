import Foundation
import GChatBridgeCore

/// `list_members` on the probed conversation, when it is a space
/// (mention composer spec §3.2): counts only, so the report can be pasted into
/// `findings.md`. Sends nothing; the owner's live mention is the send check.
extension APIProbeReport {
    static func appendMemberListSection(client: ProtoAPIClient, group: GroupId, lines: inout [String]) async {
        lines.append("member list (list_members, counts only):")
        guard case .spaceID = group.id else {
            lines.append("  not a space - list_members is asked only for spaces")
            lines.append("")
            return
        }
        var pages: [ListMembersResponse] = []
        var token: String?
        repeat {
            do {
                let page = try await client.call(
                    .listMembers, MembersRequests.listMembers(group: group, pageToken: token)
                )
                pages.append(page)
                token = page.nextPageToken.isEmpty ? nil : page.nextPageToken
            } catch {
                lines.append("  FAILED: \(safeDescription(of: error))")
                lines.append("")
                return
            }
        } while token != nil && pages.count < LocalBridgeBackend.memberPageLimit
        lines.append(contentsOf: memberListLines(pages))
        lines.append("")
    }

    static func memberListLines(_ pages: [ListMembersResponse]) -> [String] {
        let rows = pages.flatMap(\.memberships)
        func tally(_ values: [Int]) -> String {
            Dictionary(values.map { ($0, 1) }, uniquingKeysWith: +)
                .sorted { $0.key < $1.key }
                .map { "\($0.key)×\($0.value)" }
                .joined(separator: " ")
        }
        return [
            "  pages: \(pages.count)",
            "  rows: \(rows.count)",
            "  states: \(tally(rows.map(\.membershipState.rawValue)))",
            "  roles: \(tally(rows.map(\.membershipRole.rawValue)))",
            "  next_page_token on last page: \(!(pages.last?.nextPageToken.isEmpty ?? true))"
        ]
    }
}
