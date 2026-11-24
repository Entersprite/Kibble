import ChatKit

extension FixtureAudioCallService {
    private func applyMeetingAccess(_ activity: CallActivity) throws {
        guard activity.options.count == 1, let preset = activity.options.first,
              activityState.hostSettings?.meetingAccess?.availablePresets.contains(preset) == true
        else { throw ChatError.unsupported(capability: "meetingAccess") }
        activityState.hostSettings?.meetingAccess?.preset = preset
        setActivityAvailability("allowJoinRequests", available: preset != "open")
    }

    private func setActivityAvailability(_ action: String, available: Bool) {
        activityState.availableActions.removeAll { $0 == action }
        if available {
            activityState.availableActions.append(action)
        }
    }

    func applyHostSetting(_ activity: CallActivity) throws {
        switch activity.action {
        case "setMeetingAccess": try applyMeetingAccess(activity)
        case "hostManagement":
            activityState.hostSettings?.managementEnabled = activity.enabled
            let controls = ["allowReactions", "endConference", "allowChatMessages", "allowScreenSharing"]
            let participants = ["allowMicrophone", "allowCamera", "setCohost", "muteAllParticipants"]
            (controls + participants).forEach { setActivityAvailability($0, available: activity.enabled) }
        case "allowChatMessages": activityState.hostSettings?.chatMessagesAllowed = activity.enabled
        case "allowScreenSharing": activityState.hostSettings?.screenSharingAllowed = activity.enabled
        case "allowMicrophone": activityState.hostSettings?.microphoneAllowed = activity.enabled
        case "allowCamera": activityState.hostSettings?.cameraAllowed = activity.enabled
        case "allowJoiningBeforeHost": activityState.hostSettings?.joiningBeforeHostAllowed = activity.enabled
        case "allowJoinRequests": activityState.hostSettings?.meetingAccess?.joinRequestsAllowed = activity
            .enabled
        default:
            activityState.hostSettings?.reactionsAllowed = activity.enabled
            setActivityAvailability("react", available: activity.enabled)
        }
    }
}
