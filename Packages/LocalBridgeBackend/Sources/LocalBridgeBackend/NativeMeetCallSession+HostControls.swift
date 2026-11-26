import ChatKit
import Foundation
import GChatBridgeCore

extension NativeMeetCallSession {
    struct HostControlsState {
        var settings: CallHostSettings?
        var access: MeetActivityCollections.HostAccess?
        var removalGrant: (version: UInt64, enabled: Bool)?
        var sharedPinGrant: (version: UInt64, enabled: Bool)?
        var waitingRoomChatGrant: (version: UInt64, enabled: Bool)?
        var waitingParticipants: [String: CallWaitingParticipant] = [:]
        var waitingAccess: AdmissionAccess?
        var waitingRoomEnabled: Bool?
        var savedJoiningBeforeHostAllowed: Bool?
        var savedAccessPreset: MeetActivityWire.AccessPreset?
        var savedJoinRequestsAllowed: Bool?
        var continuousChatGroup: Conversation.ID?
        var continuousChatAccess: (version: UInt64, eligible: Bool)?
        var reactionsLocked = false
        var activeChatMessagesAllowed: Bool?
        var savedChatMessagesAllowed: Bool?
        var activeScreenSharingAllowed: Bool?
        var savedScreenSharingAllowed: Bool?
        var activeMicrophoneAllowed: Bool?
        var activeCameraAllowed: Bool?
        var microphoneInterruptionVersion = 0
        var remoteMute = RemoteMuteState()
    }

    struct LocalCapturePermissions {
        let microphone: Bool
        let camera: Bool
        let screen: Bool
    }

    enum HostActivity: String {
        case hostManagement, allowReactions, allowChatMessages, allowScreenSharing
        case allowMicrophone, allowCamera, allowJoiningBeforeHost, allowJoinRequests

        func value(in settings: CallHostSettings) -> Bool? {
            switch self {
            case .hostManagement: settings.managementEnabled
            case .allowReactions: settings.reactionsAllowed
            case .allowChatMessages: settings.chatMessagesAllowed
            case .allowScreenSharing: settings.screenSharingAllowed
            case .allowMicrophone: settings.microphoneAllowed
            case .allowCamera: settings.cameraAllowed
            case .allowJoiningBeforeHost: settings.joiningBeforeHostAllowed
            case .allowJoinRequests: settings.meetingAccess?.joinRequestsAllowed
            }
        }

        var wireField: MeetActivityWire.HostSetting {
            switch self {
            case .hostManagement: .management
            case .allowReactions: .reactions
            case .allowChatMessages: .chatMessages
            case .allowScreenSharing: .screenSharing
            case .allowMicrophone: .microphone
            case .allowCamera: .camera
            case .allowJoiningBeforeHost: .allowJoiningBeforeHost
            case .allowJoinRequests: .allowJoinRequests
            }
        }
    }

    private func decodeHostSettings(_ space: Data) -> CallHostSettings? {
        MeetActivityWire.hostSettings(in: space).map {
            CallHostSettings(
                managementEnabled: $0.managementEnabled,
                reactionsAllowed: $0.reactionsAllowed,
                chatMessagesAllowed: MeetActivityWire.chatSendingPolicy(in: space, includingDefault: true),
                screenSharingAllowed: MeetActivityWire.screenSharingPolicy(in: space),
                microphoneAllowed: MeetActivityWire.microphonePolicy(in: space),
                cameraAllowed: MeetActivityWire.cameraPolicy(in: space),
                joiningBeforeHostAllowed: MeetActivityWire.joiningBeforeHostAllowed(in: space),
                waitingRoomEnabled: MeetActivityWire.waitingRoomEnabled(in: space),
                meetingAccess: MeetActivityWire.meetingAccessPreset(in: space).map { preset in
                    CallMeetingAccess(
                        preset: preset.rawValue,
                        availablePresets: MeetActivityWire.availableMeetingAccessPresets(in: space)
                            .map(\.rawValue),
                        joinRequestsAllowed: MeetActivityWire.joinRequestsAllowed(in: space)
                    )
                }
            )
        }
    }

    func reconcileHostControls(_ snapshot: MeetActivityCollections.Snapshot) {
        defer { reconcileWaitingParticipants(snapshot.devices) }
        reconcileContinuousChat(snapshot)
        reconcileSharedPinGrant(snapshot.hostAccess)
        reconcileWaitingRoomChatGrant(snapshot.hostAccess)
        if let access = snapshot.hostAccess,
           hostControls.removalGrant.map({
               access.version > $0.version || (access.version == $0.version && !access.canRemoveParticipants)
           }) ?? true {
            hostControls.removalGrant = (access.version, access.canRemoveParticipants)
        }
        if let access = snapshot.hostAccess,
           hostControls.access.map({
               access.version > $0.version || (access.version == $0.version
                   && (!access.canManage || ($0.role == .host && access.role == .cohost)))
           }) ?? true {
            hostControls.access = access
        }
        guard let version = snapshot.versions[1], let space = snapshot.space,
              activityVersions[1].map({ version > $0 }) ?? true else { return }
        hostControls.settings = decodeHostSettings(space)
        hostControls.waitingRoomEnabled = MeetActivityWire.waitingRoomEnabled(in: space)
        hostControls.savedJoiningBeforeHostAllowed = MeetActivityWire.joiningBeforeHostAllowed(
            in: space,
            saved: true
        )
        hostControls.savedAccessPreset = MeetActivityWire.meetingAccessPreset(in: space, saved: true)
        hostControls.savedJoinRequestsAllowed = MeetActivityWire.joinRequestsAllowed(in: space, saved: true)
        hostControls.activeChatMessagesAllowed = MeetActivityWire.chatSendingPolicy(in: space)
        hostControls.savedChatMessagesAllowed = MeetActivityWire.chatSendingPolicy(in: space, saved: true)
        if let allowed = MeetActivityWire.screenSharingPolicy(in: space) {
            hostControls.activeScreenSharingAllowed = allowed
        }
        hostControls.savedScreenSharingAllowed = MeetActivityWire.screenSharingPolicy(in: space, saved: true)
        if let allowed = MeetActivityWire.microphonePolicy(in: space) {
            hostControls.activeMicrophoneAllowed = allowed
        }
        if let allowed = MeetActivityWire.cameraPolicy(in: space) {
            hostControls.activeCameraAllowed = allowed
        }
        if let settings = hostControls.settings {
            hostControls.reactionsLocked = !settings.reactionsAllowed
        } else if let info = try? MeetActivityCollections.bytes(6, space),
                  let settings = try? MeetActivityCollections.bytes(11, info) {
            hostControls.reactionsLocked = MeetActivityCollections.number(9, settings) == 1
        }
    }

    var canSendMeetingChat: Bool {
        if hostControls.activeChatMessagesAllowed == false {
            // The modern hosts-only policy also sets the legacy lock bit.
            return hostControls.access?.canManage == true
        }
        return !activityChatLocked
    }

    var canStartPresentation: Bool {
        hostControls.activeScreenSharingAllowed != false || hostControls.access?.canManage == true
    }

    var localCapturePermissions: LocalCapturePermissions {
        let host = hostControls.access?.canManage == true
        return LocalCapturePermissions(
            microphone: host || hostControls.activeMicrophoneAllowed != false,
            camera: host || hostControls.activeCameraAllowed != false,
            screen: canStartPresentation
        )
    }

    func availableHostActions() -> [String] {
        activities.hostSettings = !unavailableActivityFields.contains(1) && hostControls.access?
            .canManage == true
            ? hostControls.settings : nil
        let canRemove = hostControls.removalGrant?.enabled == true
        var actions = canRemove ? ["removeParticipant", "blockParticipant"] : []
        if hostControls.access?.canManage == true {
            actions += ["lowerParticipantHand", "lowerAllHands"]
        }
        activities.sharedPinLimit = nil
        if hostControls.sharedPinGrant?.enabled == true {
            actions.append("setPinForEveryone")
            activities.sharedPinLimit = Self.sharedPinLimit
        }
        actions += admissionAccess?.actions ?? []
        if canRemove, hostControls.access?.role == .host {
            actions.append("sendParticipantToWaitingRoom")
        }
        guard let settings = activities.hostSettings else { return actions }
        let primaryHost = hostControls.access?.role == .host
        if primaryHost {
            actions += organizerAdmissionActions(settings)
        }
        if settings.managementEnabled || primaryHost {
            actions += [HostActivity.hostManagement.rawValue, "muteParticipant"]
        }
        if settings.managementEnabled {
            actions += [HostActivity.allowReactions.rawValue, "endConference"]
            if primaryHost {
                actions.append("setCohost")
                actions.append("muteAllParticipants")
            }
            let optional: [HostActivity] = [
                .allowChatMessages, .allowScreenSharing, .allowMicrophone, .allowCamera
            ]
            actions += optional.filter { $0.value(in: settings) != nil }.map(\.rawValue)
        }
        return actions
    }

    private func organizerAdmissionActions(_ settings: CallHostSettings) -> [String] {
        var actions: [String] = []
        if settings.waitingRoomEnabled != true, settings.joiningBeforeHostAllowed != nil {
            actions.append(HostActivity.allowJoiningBeforeHost.rawValue)
        }
        if let access = settings.meetingAccess,
           access.availablePresets.contains(where: { $0 != access.preset }) {
            actions.append("setMeetingAccess")
        }
        if settings.meetingAccess?.joinRequestsAllowed != nil {
            actions.append(HostActivity.allowJoinRequests.rawValue)
        }
        return actions
    }

    private func verifyHostAction(_ action: String) async throws -> (UInt64, CallHostSettings) {
        let before = try await device.activityCollections(refreshHostAccess: true)
        try await check()
        await reconcileActivities(before)
        try await check()
        guard !isSuspended, disconnectedAt == nil,
              let access = before.hostAccess, access.canManage,
              access.version == hostControls.access?.version,
              let version = before.versions[1], version == activityVersions[1],
              let space = before.space, let settings = activities.hostSettings,
              decodeHostSettings(space) == settings,
              matchesSavedHostSetting(action, in: space),
              activities.availableActions.contains(action) else {
            throw ChatError.unsupported(capability: "meetingHostControls")
        }
        return (version, settings)
    }

    func endConference(_ activity: CallActivity) async throws {
        guard activity.enabled else { throw ChatError.unsupported(capability: "meetingHostControls") }
        _ = try await verifyHostAction(activity.action)
        try await device.endConference()
    }

    func updateHostSetting(_ setting: HostActivity, enabled: Bool) async throws {
        if setting == .allowJoiningBeforeHost, deniedActivities.contains(setting.rawValue) {
            throw ChatError.unsupported(capability: "meetingHostControls")
        }
        let space = await device.activitySpace
        let (version, settings) = try await verifyHostAction(setting.rawValue)
        guard !matchesHostSetting(setting, enabled: enabled, settings: settings) else { return }
        let request = try MeetActivityWire.hostSetting(
            setting.wireField, space: space, enabled: enabled, requestID: UUID()
        )
        try await writeHostSetting(request, after: version) { settings in
            matchesHostSetting(setting, enabled: enabled, settings: settings)
        }
    }

    func updateMeetingAccess(_ activity: CallActivity) async throws {
        guard activity.options.count == 1,
              let preset = MeetActivityWire.AccessPreset(rawValue: activity.options[0])
        else { throw ChatError.unsupported(capability: "meetingAccess") }
        let space = await device.activitySpace
        let (version, settings) = try await verifyHostAction(activity.action)
        guard let access = settings.meetingAccess, access.availablePresets.contains(preset.rawValue)
        else { throw ChatError.unsupported(capability: "meetingAccess") }
        guard access.preset != preset.rawValue || hostControls.savedAccessPreset != preset else { return }
        let request = try MeetActivityWire.meetingAccessPreset(preset, space: space, requestID: UUID())
        try await writeHostSetting(request, after: version) { settings in
            settings.meetingAccess?.preset == preset.rawValue && hostControls.savedAccessPreset == preset
        }
    }

    private func writeHostSetting(
        _ request: MeetActivityWire.Request, after version: UInt64, matches: (CallHostSettings) -> Bool
    ) async throws {
        _ = try await device.performActivity(request)
        try await check()
        let after = try await device.activityCollections(refreshHostAccess: true)
        try await check()
        await reconcileActivities(after)
        try await check()
        guard let revision = after.versions[1], revision > version, revision == activityVersions[1],
              let settings = hostControls.settings, matches(settings) else {
            throw ChatError.transport("The host setting change could not be confirmed.")
        }
    }

    private func matchesHostSetting(
        _ setting: HostActivity,
        enabled: Bool,
        settings: CallHostSettings
    ) -> Bool {
        guard setting.value(in: settings) == enabled else { return false }
        switch setting {
        case .allowChatMessages:
            return hostControls.activeChatMessagesAllowed == enabled
                && hostControls.savedChatMessagesAllowed == enabled
        case .allowScreenSharing: return hostControls.savedScreenSharingAllowed == enabled
        case .allowJoiningBeforeHost: return hostControls.savedJoiningBeforeHostAllowed == enabled
        case .allowJoinRequests: return hostControls.savedJoinRequestsAllowed == enabled
        default: return true
        }
    }

    private func matchesSavedHostSetting(_ action: String, in space: Data) -> Bool {
        switch action {
        case "setMeetingAccess":
            MeetActivityWire.meetingAccessPreset(in: space, saved: true) == hostControls.savedAccessPreset
        case HostActivity.allowChatMessages.rawValue:
            MeetActivityWire.chatSendingPolicy(in: space, saved: true)
                == hostControls.savedChatMessagesAllowed
        case HostActivity.allowScreenSharing.rawValue:
            MeetActivityWire.screenSharingPolicy(in: space, saved: true)
                == hostControls.savedScreenSharingAllowed
        case HostActivity.allowJoiningBeforeHost.rawValue:
            MeetActivityWire.joiningBeforeHostAllowed(in: space, saved: true) == hostControls
                .savedJoiningBeforeHostAllowed
        case HostActivity.allowJoinRequests.rawValue:
            MeetActivityWire.joinRequestsAllowed(in: space, saved: true) == hostControls
                .savedJoinRequestsAllowed
        default: true
        }
    }
}
