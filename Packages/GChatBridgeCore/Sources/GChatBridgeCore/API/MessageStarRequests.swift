import Foundation

/// Personal message stars and their account-wide entity section.
public enum MessageStarRequests {
    public struct Page: Sendable {
        public let messages: [Message]
        public let nextCursor: String?
    }

    public enum Failure: Error, Equatable {
        case invalidCursor
        case missingStarredSection
        case incompletePage
    }

    private static let labelType: Int32 = 1
    private static let pageSize: Int32 = 30
    private static let cursorByteLimit = 4096

    public static func apply(_ id: MessageId) -> ApplyMessageLabelRequest {
        var request = ApplyMessageLabelRequest()
        request.requestHeader = APIRequestHeader.make()
        request.messageID = id
        request.label.labelType = labelType
        return request
    }

    public static func remove(_ id: MessageId) -> RemoveMessageLabelRequest {
        var request = RemoveMessageLabelRequest()
        request.requestHeader = APIRequestHeader.make()
        request.messageID = id
        request.label.labelType = labelType
        return request
    }

    public static func isStarred(_ message: Message) -> Bool {
        message.personalLabelTags.contains { $0.labelType == labelType }
    }

    public static func list(after cursor: String? = nil) throws -> PaginatedEntityWorldRequest {
        var section = WorldEntitySectionRequest()
        section.pageSize = pageSize
        section.entityFilter = starredFilter
        section.entityOptions.sortOptions.direction = 1
        section.entityOptions.sortOptions.byLabelAppliedTime = true
        section.entityOptions.hydrationOptions.includeEntity = true
        section.sort.sortKey = .sortByStarredLabelAppliedTime
        if let cursor {
            guard validCursor(cursor) else { throw Failure.invalidCursor }
            section.sort.sortValue = cursor
        }
        var request = PaginatedEntityWorldRequest()
        request.requestHeader = APIRequestHeader.make()
        request.sections = [section]
        request.fetchOptions = [
            .fetchGroupsD3Policies, .fetchBotsInHumanDm, .fetchUserProfilesForGroupNaming,
            .fetchSnippetSenderProfiles, .fetchThreadMessageSenderProfiles, .fetchSpaceIntegrationPayloads
        ]
        request.registerWorldClient = false
        return request
    }

    public static func page(from response: PaginatedWorldResponse) throws -> Page {
        let sections = response.worldSectionResponses
            .filter { $0.hasEntityFilter && $0.entityFilter == starredFilter }
        guard sections.count == 1, let section = sections.first else { throw Failure.missingStarredSection }
        let cursor = section.hasMoreItems_p ? section.paginationToken : nil
        if let cursor, !validCursor(cursor) {
            throw Failure.incompletePage
        }
        let messages = response.worldEntities.lazy.filter(\.hasMessage).map(\.message).filter {
            let topic = $0.id.parentID.topicID
            return $0.deleteTime == 0 && !$0.id.messageID.isEmpty && !topic.topicID.isEmpty
                && topic.groupID.id != nil && isStarred($0)
        }
        return Page(messages: Array(messages), nextCursor: cursor)
    }

    private static func validCursor(_ cursor: String) -> Bool {
        !cursor.isEmpty && cursor.utf8.count <= cursorByteLimit
    }

    private static var starredFilter: WorldEntityFilter {
        var term = WorldEntityFilterTerm()
        term.entityType = 3
        term.expression.fieldEquals.field = 2
        term.expression.fieldEquals.fieldArgument.value = "label"
        // Unpadded base32hex of the one-field protobuf MessageLabel(type: 1).
        term.expression.fieldEquals.operand.value = "100G"
        var filter = WorldEntityFilter()
        filter.terms = [term]
        return filter
    }
}

public extension APIMethod where Request == PaginatedEntityWorldRequest, Response == PaginatedWorldResponse {
    static var starredMessages: Self {
        Self("paginated_world")
    }
}
