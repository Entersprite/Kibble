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
        let status: ConversationCallStatus = if call.hasCallStatus, call.callStatus == 3 {
            .inactive
        } else if call.hasCallStatus, call.callStatus == 1, meet.hasMeetingType, meet.meetingType == 1 {
            .active
        } else {
            .unknown("unrecognized")
        }
        let reference = CallMessageMapping.validReference(meet.meetingCode) ? meet.meetingCode : nil
        let people = status == .active ? roster.map {
            $0.memberIDs.map { ConversationCallParticipant(memberID: .init($0)) }
                + $0.anonymousNames.map { ConversationCallParticipant(displayName: $0) }
        } : nil
        return .init(
            conversationID: id, status: status, checkedAt: date,
            reference: reference,
            joinURL: CallMessageMapping.joinURL(meet.meetingURL, reference: reference),
            participantsChangedAt: call.hasParticipantListRevisionTimestamp
                ? CallMessageMapping.date(call.participantListRevisionTimestamp) : nil,
            participants: people, totalParticipants: people == nil ? nil : roster?.totalCount
        )
    }
}
