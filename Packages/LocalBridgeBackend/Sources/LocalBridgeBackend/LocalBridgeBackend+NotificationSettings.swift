import ChatKit
import Foundation
import GChatBridgeCore

struct PendingNotificationWrite {
    let id = UUID()
    var observedUpdates = 0
    var requested: GroupNotificationMapping?

    mutating func observe(level: NotificationLevel?, muted: Bool?, muteUntil: Date?) {
        if let requested,
           level == nil || level == requested.level,
           muted == nil || (muted == requested.isMuted && muteUntil == requested.muteUntil) {
            return
        }
        observedUpdates += 1
    }
}

public extension LocalBridgeBackend {
    func setNotificationSetting(_ level: NotificationLevel, for id: Conversation.ID) async throws {
        guard let roomLevel = Self.roomLevel(level) else {
            throw ChatError.unsupported(capability: "canSetNotificationLevel")
        }
        try await updateNotificationSettings(.level(roomLevel), in: id)
    }

    func setConversationMute(_ pause: Pause, in id: Conversation.ID) async throws {
        try await updateNotificationSettings(.mute(pause), in: id)
    }
}

private enum NotificationMutation {
    case level(GroupNotificationSettings.RoomNotificationState)
    case mute(Pause)

    var capability: String {
        switch self {
        case .level: "canSetNotificationLevel"
        case .mute: "conversationMute"
        }
    }

    func request(
        in group: GroupId, settings: GroupNotificationSettings
    ) throws -> UpdateGroupNotificationSettingsRequest {
        switch self {
        case let .level(level):
            GroupNotificationRequests.updateLevel(level, in: group)
        case let .mute(pause):
            try Self.muteRequest(pause, in: group, settings: settings)
        }
    }

    private static func muteRequest(
        _ pause: Pause, in group: GroupId, settings: GroupNotificationSettings
    ) throws -> UpdateGroupNotificationSettingsRequest {
        switch pause {
        case .off: return GroupNotificationRequests.updateMute(
                .unmuted,
                expiry: nil,
                in: group,
                over: settings
            )
        case .untilResumed:
            return GroupNotificationRequests.updateMute(.muted, expiry: nil, in: group, over: settings)
        case let .until(date):
            let duration = date.timeIntervalSinceNow
            guard duration > 0, duration <= 120 * 86400,
                  let millis = Int64(exactly: (date.timeIntervalSince1970 * 1000).rounded())
            else { throw ChatError.unknown("Choose a time in the future, up to 120 days away.") }
            var timestamp = ComGoogleProtobufTimestamp()
            timestamp.seconds = millis / 1000
            timestamp.nanos = Int32(millis % 1000) * 1_000_000
            return GroupNotificationRequests.updateMute(.muted, expiry: timestamp, in: group, over: settings)
        case .unknown: throw ChatError.unsupported(capability: "conversationMute")
        }
    }
}

extension LocalBridgeBackend {
    private func updateNotificationSettings(
        _ mutation: NotificationMutation,
        in id: Conversation.ID
    ) async throws {
        guard isConnected, let client = apiClient else { throw ChatError.notAuthenticated }
        guard let group = ChannelEventMapping.groupID(for: id)
        else { throw ChatError.unsupported(capability: mutation.capability) }
        if case .level = mutation, case .dmID = group.id {
            throw ChatError.unsupported(capability: mutation.capability)
        }
        guard notificationWrites[id] == nil else {
            throw ChatError.unknown("A notification change is already in progress.")
        }
        let generation = directoryGeneration
        let write = PendingNotificationWrite()
        notificationWrites[id] = write
        defer {
            if notificationWrites[id]?.id == write.id {
                notificationWrites[id] = nil
            }
        }
        do {
            try await saveNotificationSettings(
                mutation,
                id: id,
                group: group,
                client: client,
                generation: generation
            )
        } catch let error as APIFailure {
            throw Self.chatError(fromAPI: error, call: "conversation notification settings")
        }
    }
}

extension LocalBridgeBackend {
    private func saveNotificationSettings(
        _ mutation: NotificationMutation, id: Conversation.ID, group: GroupId, client: ProtoAPIClient,
        generation: Int
    ) async throws {
        let admissionUpdates = notificationWrites[id]?.observedUpdates
        let before = try await readAddressedManagementGroup(group, client: client, generation: generation)
        guard notificationWrites[id]?.observedUpdates == admissionUpdates else {
            throw ChatError.unknown("The conversation setting changed. Check it before saving again.")
        }
        guard let conversation = ManagementMapping.conversation(
            before.group, fallback: conversationDetails[id].flatMap(WorldMapping.conversation)
        ), canChange(mutation, in: conversation.kind), before.membershipState == .memberJoined else {
            throw ChatError.unsupported(capability: mutation.capability)
        }
        let request = try mutation.request(
            in: group,
            settings: before.group.groupReadState.notificationSettings
        )
        // A matching channel echo can arrive during the addressed readback.
        notificationWrites[id]?.requested = GroupNotificationMapping(request.settings)
        _ = try await client.call(.updateGroupNotificationSettings, request)
        try checkManagementGeneration(generation)
        let observedUpdates = notificationWrites[id]?.observedUpdates
        let after = try await readAddressedManagementGroup(group, client: client, generation: generation)
        let readState = after.group.groupReadState
        let settings = GroupNotificationMapping(readState)
        guard notificationWrites[id]?.observedUpdates == observedUpdates,
              after.membershipState == .memberJoined,
              settings.level == GroupNotificationMapping(request.settings).level,
              Self.confirmsMute(
                  readState.notificationSettings.muteSettings,
                  requested: request.settings.muteSettings
              )
        else {
            throw ChatError.unknown("Google Chat did not confirm the conversation notification setting.")
        }
        conversationDetails[id]?.readState.notificationSettings = readState.notificationSettings
        guard await emitCommitted(.conversationNotificationSettingsChanged(
            conversationID: id, level: settings.level, muted: settings.isMuted, muteUntil: settings.muteUntil
        )) else { throw ChatError.unknown("The confirmed notification setting could not be synced.") }
        try checkManagementGeneration(generation)
    }

    private func canChange(_ mutation: NotificationMutation, in kind: Conversation.Kind) -> Bool {
        switch mutation {
        case .level: kind == .space
        case .mute: capabilities.canSetConversationMute(in: kind)
        }
    }

    private static func confirmsMute(
        _ answer: GroupNotificationSettings.MuteSettings,
        requested: GroupNotificationSettings.MuteSettings
    ) -> Bool {
        guard answer.state == requested.state else { return false }
        return answer.expiry.seconds == requested.expiry.seconds && answer.expiry.nanos == requested.expiry
            .nanos
    }

    func readAddressedManagementGroup(
        _ group: GroupId, client: ProtoAPIClient, generation: Int
    ) async throws -> GetGroupResponse {
        try checkManagementGeneration(generation)
        let response = try await client.call(
            .managementDetails,
            ConversationManagementRequests.details(group)
        )
        try checkManagementGeneration(generation)
        guard response.hasGroup, response.group.groupID == group else {
            throw ChatError.decoding("Google Chat did not return this conversation.")
        }
        return response
    }

    private static func roomLevel(_ level: NotificationLevel)
        -> GroupNotificationSettings.RoomNotificationState? {
        switch level {
        case .always: .notifyAll
        case .lessWithNewThreads: .notifyMainConversation
        case .less: .notifyLess
        case .never: .notifyNever
        case .unknown: nil
        }
    }
}
