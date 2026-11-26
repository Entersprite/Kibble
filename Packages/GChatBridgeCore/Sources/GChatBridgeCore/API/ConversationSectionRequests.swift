public enum ConversationSectionRequests {
    public static func changeLabel(_ label: GroupLabel, in group: GroupId) -> ChangeGroupLabelRequest {
        var request = ChangeGroupLabelRequest()
        request.requestHeader = APIRequestHeader.make()
        request.label = label
        request.groupID = group
        return request
    }

    public static func list() -> PaginatedWorldRequest {
        var request = WorldRequestLadder.minimumViable.request
        request.fetchOptions.append(.fetchRosterSections)
        request.registerWorldClient = false
        request.badgeFetchOptions = [1]
        return request
    }

    public static func customLabelKey(_ label: GroupLabel) -> String? {
        label.type == 4 && validIdentifier(label.secondaryKey) ? label.secondaryKey : nil
    }

    public static func customSectionID(_ id: RosterSectionID) -> String? {
        id.type == 3 && validIdentifier(id.id) ? id.id : nil
    }

    private static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 512 && !value.contains("\0")
    }

    public static func create(
        name: String,
        temporaryID: String,
        position: Int32
    ) -> CreateRosterSectionRequest {
        var request = CreateRosterSectionRequest()
        request.requestHeader = APIRequestHeader.make()
        request.section.id.type = 3
        request.section.id.id = temporaryID
        request.section.id.label.type = 4
        request.section.id.label.secondaryKey = temporaryID
        request.section.position = position
        request.section.name = name
        request.section.contentSort.order = 1
        return request
    }

    public static func delete(_ id: RosterSectionID) -> DeleteRosterSectionRequest {
        var request = DeleteRosterSectionRequest()
        request.sectionID = id
        request.requestHeader = APIRequestHeader.make()
        return request
    }

    public static func update(
        _ current: RosterSectionDefinition, name: String?, unreadOnly: Bool?, sort: Int32?
    ) -> UpdateRosterSectionRequest {
        var request = UpdateRosterSectionRequest()
        request.requestHeader = APIRequestHeader.make()
        request.section.id = current.id
        let order = sort ?? (current.contentSort.order == 2 ? 2 : 1)
        request.section.contentSort.order = order
        if order == 1 {
            request.section.activityItemCount = current.visibleItemCount
        }
        if let name {
            request.section.name = name
            request.updateMask.wholeFields.append(3)
        }
        if let unreadOnly {
            request.section.unreadOnly = unreadOnly
            request.updateMask.wholeFields.append(4)
        }
        if sort != nil {
            request.updateMask.wholeFields.append(10)
        }
        request.updateMask.inverted = false
        return request
    }
}

public extension APIMethod where Request == ChangeGroupLabelRequest, Response == ChangeGroupLabelResponse {
    static var applyGroupLabel: Self {
        Self("apply_group_label", allowsEmptyResponse: true)
    }

    static var removeGroupLabel: Self {
        Self("remove_group_label", allowsEmptyResponse: true)
    }
}

public extension APIMethod where Request == CreateRosterSectionRequest,
    Response == CreateRosterSectionResponse {
    static var createRosterSection: Self {
        Self("create_roster_section", allowsEmptyResponse: true)
    }
}

public extension APIMethod where Request == DeleteRosterSectionRequest,
    Response == DeleteRosterSectionResponse {
    static var deleteRosterSection: Self {
        Self("delete_roster_section", allowsEmptyResponse: true)
    }
}

public extension APIMethod where Request == UpdateRosterSectionRequest,
    Response == UpdateRosterSectionResponse {
    static var updateRosterSection: Self {
        Self("update_roster_section", allowsEmptyResponse: true)
    }
}
