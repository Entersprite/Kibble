/// Read-only call participants scoped to the addressed conversation.
public enum CallDiscoveryRequests {
    public struct Participants: Sendable, Equatable {
        public let memberIDs: [String]
        public let anonymousNames: [String?]
        public let totalCount: Int
    }

    public enum Failure: Error { case invalidGroup, malformedParticipants }

    public static func participants(in group: GroupId) throws -> GetCallDataRequest {
        let id: String = switch group.id {
        case let .dmID(value): value.dmID
        case let .spaceID(value): value.spaceID
        case nil: ""
        }
        guard !id.isEmpty, id.utf8.count <= 128 else { throw Failure.invalidGroup }
        var request = GetCallDataRequest()
        request.requestHeader = APIRequestHeader.make()
        request.groupID = group
        request.fetchOptions = [1]
        return request
    }

    public static func participants(from response: GetCallDataResponse) throws -> Participants {
        guard response.hasParticipantList else { throw Failure.malformedParticipants }
        let list = response.participantList
        guard list.hasTotalCount, list.totalCount <= 10000, list.users.count <= 256,
              list.anonymousParticipants.count <= 256,
              list.users.count + list.anonymousParticipants.count <= Int(list.totalCount)
        else { throw Failure.malformedParticipants }
        let ids = list.users.map(\.id)
        guard ids.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }), Set(ids).count == ids.count,
              list.anonymousParticipants.allSatisfy({ $0.displayName.utf8.count <= 1024 })
        else { throw Failure.malformedParticipants }
        return Participants(
            memberIDs: ids,
            anonymousNames: list.anonymousParticipants.map { $0.displayName.isEmpty ? nil : $0.displayName },
            totalCount: Int(list.totalCount)
        )
    }
}

public extension APIMethod where Request == GetCallDataRequest, Response == GetCallDataResponse {
    static var getCallData: Self {
        Self("get_call_data")
    }
}
