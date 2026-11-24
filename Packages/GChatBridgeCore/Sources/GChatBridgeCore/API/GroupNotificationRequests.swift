/// The web client's space Notifications save.
public enum GroupNotificationRequests {
    public static func updateLevel(
        _ level: GroupNotificationSettings.RoomNotificationState, in group: GroupId
    ) -> UpdateGroupNotificationSettingsRequest {
        var request = UpdateGroupNotificationSettingsRequest()
        request.requestHeader = APIRequestHeader.make()
        request.groupID = group
        request.settings.roomState = level
        request.settings.muteSettings.state = .unmuted
        return request
    }

    public static func updateMute(
        _ state: GroupNotificationSettings.MuteSettings.State, expiry: ComGoogleProtobufTimestamp?,
        in group: GroupId, over settings: GroupNotificationSettings
    ) -> UpdateGroupNotificationSettingsRequest {
        var request = UpdateGroupNotificationSettingsRequest()
        request.requestHeader = APIRequestHeader.make()
        request.groupID = group
        request.settings = settings
        var mute = GroupNotificationSettings.MuteSettings()
        mute.state = state
        if let expiry {
            mute.expiry = expiry
        }
        request.settings.muteSettings = mute
        return request
    }
}

public extension APIMethod
    where Request == UpdateGroupNotificationSettingsRequest,
    Response == UpdateGroupNotificationSettingsResponse {
    static var updateGroupNotificationSettings: Self {
        Self("update_group_notification_settings", allowsEmptyResponse: true)
    }
}
