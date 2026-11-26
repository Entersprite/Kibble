import Foundation

/// The web client's ordinary unsent messages, independent of scheduled delivery.
public enum SyncedDraftRequests {
    public enum Scope: Sendable {
        case account
        case group(GroupId)
        case thread(group: GroupId, topicID: String)
    }

    public static func list(in scope: Scope, after cursor: String?) -> ListUnsentMessagesRequest {
        var request = ListUnsentMessagesRequest()
        request.requestHeader = APIRequestHeader.make()
        request.options.pageSize = 30
        if let cursor {
            request.options.cursor = cursor
        }
        request.scope.unsentType = 2
        request.scope.listMode = 0
        switch scope {
        case .account:
            break
        case let .group(group):
            request.scope.groupID = group
            request.scope.groupOnly = true
        case let .thread(group, topicID):
            request.scope.groupID = group
            request.scope.topicID.groupID = group
            request.scope.topicID.topicID = topicID
        }
        return request
    }

    public static func content(
        id: UnsentMessageId, text: String, annotations: [Annotation], reference: UnsentMessageReference?
    ) -> UnsentMessage {
        var record = UnsentMessage()
        record.id = id
        record.text = text
        record.annotations = annotations
        if let reference {
            record.reference = reference
        }
        record.clientSyncValue = UUID().uuidString
        return record
    }

    public static func create(_ record: UnsentMessage) -> CreateUnsentMessageRequest {
        var request = CreateUnsentMessageRequest()
        request.requestHeader = APIRequestHeader.make()
        request.message = record
        request.message.unsentType = 2
        return request
    }

    public static func edit(_ record: UnsentMessage) -> UpdateUnsentMessageRequest {
        var request = UpdateUnsentMessageRequest()
        request.requestHeader = APIRequestHeader.make()
        request.message = record
        request.updateMask.wholeFields = [4, 5, 6, 9]
        request.updateMask.inverted = false
        return request
    }
}
