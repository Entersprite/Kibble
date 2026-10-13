import ChatKit
import Foundation
import GChatBridgeCore

extension MeetDMCallTrial {
    func loadStoredSession() async throws -> StoredSession {
        guard let stored = try await store.currentSession() else { throw MeetDMCallTrialError.noSession }
        if let expectedSession {
            guard stored.capturedAt == expectedSession.capturedAt,
                  stored.expiresAt == expectedSession.expiresAt
            else { throw MeetDMCallTrialError.accountChanged }
        }
        return stored
    }

    static func candidates(
        _ conversations: [Conversation], selfID: String
    ) -> (targets: [Target], diagnostics: [String]) {
        var seen = Set<String>()
        var direct = 0
        var pairs = 0
        var ownerPairs = 0
        var differingEstimates = 0
        let targets: [Target] = conversations.compactMap { conversation in
            guard let dmID = MeetCallProbeReport.dmID(for: conversation) else { return nil }
            direct += 1
            let members = Set(conversation.members.map(\.rawValue))
            guard members.count == 2 else { return nil }
            pairs += 1
            guard members.contains(selfID) else { return nil }
            ownerPairs += 1
            // The segmented count is an estimate. The DM kind and actual
            // owner/peer pair establish the recipient; a different estimate
            // is diagnostic information, not grounds to discard that person.
            if let count = conversation.memberCount, count != 2 {
                differingEstimates += 1
            }
            guard
                let callee = members.first(where: { $0 != selfID }), seen.insert(callee).inserted
            else { return nil }
            return Target(conversationID: conversation.id, dmID: dmID, calleeID: callee)
        }
        return (targets, [
            "Human DM filters: \(direct) human DMs; \(pairs) with two listed members; "
                + "\(ownerPairs) including current account; "
                + "\(differingEstimates) with differing count estimates; "
                + "\(targets.count) unique recipients"
        ])
    }

    func namedPeople(
        _ candidates: [Target], using chat: ProtoAPIClient
    ) async throws -> (people: [MeetDMCallPerson], targets: [UUID: Target]) {
        guard !candidates.isEmpty else {
            lines.append("get_members: not sent; no candidate recipients")
            return ([], [:])
        }
        let response = try await chat.call(
            .getMembers, LocalBridgeBackend.getMembersRequest(candidates.map { .init($0.calleeID) })
        )
        let mapped = MemberMapping.map(response)
        lines.append(
            "get_members: accepted; \(response.members.count) profiles; "
                + "\(mapped.members.count) mapped; \(mapped.skipped) unmapped"
        )
        let members = Dictionary(
            mapped.members.map { ($0.id.rawValue, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var people: [MeetDMCallPerson] = []
        var selected: [UUID: Target] = [:]
        var matching = 0
        var human = 0
        for target in candidates {
            guard let member = members[target.calleeID] else { continue }
            matching += 1
            guard member.kind == .human else { continue }
            human += 1
            guard let name = member.displayName ?? member.email, !name.isEmpty
            else { continue }
            let id = UUID()
            people.append(MeetDMCallPerson(
                id: id, conversationID: target.conversationID, memberID: member.id,
                name: name, email: member.email
            ))
            selected[id] = target
        }
        lines.append(
            "Recipient profiles: \(matching) matched; \(human) human; \(people.count) named"
        )
        return (people, selected)
    }
}
