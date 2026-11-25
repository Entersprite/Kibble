import ChatKit
import Foundation
import GChatBridgeCore

enum CallAvailabilityMapping {
    static func payload(in group: Group) -> CallSpaceIntegrationPayload? {
        let values = group.spaceIntegrationPayloads.filter { $0.type == 5 || $0.hasCallIntegrationPayload }
        guard values.count == 1, values[0].type == 5, values[0].hasCallIntegrationPayload else { return nil }
        return values[0].callIntegrationPayload
    }

    static func map(
        _ call: CallSpaceIntegrationPayload?, in id: Conversation.ID, at date: Date,
        roster: CallDiscoveryRequests.Participants? = nil
    ) -> ConversationCallAvailability {
        guard let call else {
            return .init(conversationID: id, status: .unknown("unavailable"), checkedAt: date)
        }
        let meet = call.callMetadata.meetMetadata
        // Missed and ended both terminate the previous conversation call.
        let status: ConversationCallStatus = if call.hasCallStatus, [2, 3].contains(call.callStatus) {
            .inactive
        } else if call.hasCallStatus, call.callStatus == 1, meet.hasMeetingType, meet.meetingType == 1 {
            .active
        } else {
            .unknown("unrecognized")
        }
        let code = CallMessageMapping.validReference(meet.meetingCode) ? meet.meetingCode : nil
        let joinURL = CallMessageMapping.joinURL(meet.meetingURL, reference: code)
        let reference = code ?? (meet.hasMeetingCode ? nil : joinURL.map { String($0.path.dropFirst()) })
        let people = status == .active ? roster.map {
            $0.memberIDs.map { ConversationCallParticipant(memberID: .init($0)) }
                + $0.anonymousNames.map { ConversationCallParticipant(displayName: $0) }
        } : nil
        return .init(
            conversationID: id, status: status, checkedAt: date,
            reference: reference,
            joinURL: joinURL,
            participantsChangedAt: call.hasParticipantListRevisionTimestamp
                ? CallMessageMapping.date(call.participantListRevisionTimestamp) : nil,
            participants: people, totalParticipants: people == nil ? nil : roster?.totalCount
        )
    }
}
