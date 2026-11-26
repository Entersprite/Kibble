import ChatKit
import Foundation
import GChatBridgeCore

/// `.setStatus` and `.setAvailability` (set-your-status spec §3). Its own
/// file because `LocalBridgeBackend.swift` is at swiftlint's `file_length`.
/// `capabilities.canSetStatus` is true on Chat on the web's bundle and
/// purple, which both name the three calls; no live run has confirmed them.
///
/// Each answer's `UserStatus` is emitted as soon as it arrives rather than
/// waiting for the presence poll, but only the half the command changed:
/// nothing shows an answer is complete, and a partial one mapped whole would
/// erase your custom status after Do not disturb, or uncheck Away after a
/// status (review finding 1). A refused call throws, and `SyncEngine.submit`
/// records it for the banner; nothing was changed locally, so nothing springs
/// back. The shapes are `[Verify]` until the owner's first live use.
extension LocalBridgeBackend {
    func setOwnStatus(_ command: ChatCommand) async throws {
        guard let apiClient else {
            throw ChatError.unknown(
                "send(_:) requires connect() to succeed first - "
                    + "there is no verified session or xsrf token yet"
            )
        }
        switch command {
        case let .setStatus(status):
            let response = try await call("set_custom_status") {
                try await apiClient.call(.setCustomStatus, OwnStatusRequests.setCustomStatus(status))
            }
            emitOwnStatus(response.hasUserStatus ? response.userStatus : nil, requested: status)
        case let .setAvailability(availability):
            try await setAvailability(availability, using: apiClient)
        default:
            break
        }
    }

    private func setAvailability(_ availability: Availability, using api: ProtoAPIClient) async throws {
        let generation = directoryGeneration
        let write = UUID()
        presencePoll.ownAvailabilityRevision = write
        presencePoll.ownAvailabilityWrites.insert(write)
        defer { presencePoll.ownAvailabilityWrites.remove(write) }
        switch availability {
        case .automatic, .away:
            try await setPresenceSharing(for: availability, using: api, generation: generation)
        case let .doNotDisturb(end):
            let dnd = try await call("set_dnd_duration") {
                try await api.call(
                    .setDndDuration,
                    OwnStatusRequests.doNotDisturb(until: end, current: presencePoll.ownAvailability)
                )
            }
            try checkManagementGeneration(generation)
            emitAvailability(
                dnd.hasUserStatus ? dnd.userStatus : nil,
                requested: availability,
                call: "set_dnd_duration"
            )
        case let .unknown(raw):
            throw ChatError.unsupported(capability: raw)
        }
        // Back on Automatic shows green now, not at the next tick.
        if presencePoll.deviceInUse {
            await sendActivity(active: true)
        }
    }

    /// Ending Do not disturb can reenable presence sharing, so change sharing last.
    /// If that write fails, show the result of ending Do not disturb before reporting the error.
    private func setPresenceSharing(
        for availability: Availability, using api: ProtoAPIClient, generation: Int
    ) async throws {
        let dnd = try await call("set_dnd_duration") {
            try await api.call(
                .setDndDuration,
                OwnStatusRequests.doNotDisturbOff(current: presencePoll.ownAvailability)
            )
        }
        try checkManagementGeneration(generation)
        let sharing = availability == .automatic
        let shared: SetPresenceSharedResponse
        do {
            shared = try await call("set_presence_shared") {
                try await api.call(.setPresenceShared, OwnStatusRequests.setPresenceShared(sharing))
            }
        } catch {
            try checkManagementGeneration(generation)
            emitAvailability(
                dnd.hasUserStatus ? dnd.userStatus : nil, requested: availability, call: "set_dnd_duration"
            )
            throw error
        }
        try checkManagementGeneration(generation)
        emitAvailability(
            shared.hasUserStatus ? shared.userStatus : nil, requested: availability,
            call: "set_presence_shared"
        )
    }

    /// The exact account read also sees availability writes made in another client.
    /// Share the presence poll's lifetime without treating a failed read as a reset.
    func refreshOwnAvailability(generation: Int) async {
        guard !Task.isCancelled, directoryGeneration == generation,
              let apiClient, let me = calendarPoll.me, let current = presencePoll.ownAvailability,
              presencePoll.ownAvailabilityWrites.isEmpty else { return }
        let revision = presencePoll.ownAvailabilityRevision
        guard let response = try? await apiClient.call(.getSelfUserStatus, GetSelfUserStatusRequest()),
              !Task.isCancelled, directoryGeneration == generation,
              presencePoll.ownAvailabilityRevision == revision, response.userStatus.userID.id == me.rawValue
        else { return }
        let status = response.userStatus
        let dnd = status.dndSettings
        guard dnd.dndState != .unknown,
              dnd.dndState != .dnd || dnd.dndExpiryTimeUsec > 0 || dnd.stateRemainingDurationUsec > 0
        else { return }
        let availability = AvailabilityMapping.availability(answering: current, with: status, now: .now)
        guard availability != presencePoll.ownAvailability else { return }
        presencePoll.ownAvailability = availability
        emit(.availabilityChanged(availability))
    }

    /// One `/api/` call, its failure named for the banner.
    private func call<Response>(
        _ name: String,
        _ body: () async throws -> Response
    ) async throws -> Response {
        do {
            return try await body()
        } catch {
            // What Google said with a refusal, for the log (session 62).
            if case .httpStatus? = error as? APIFailure, let refusal = await apiClient?.lastRefusal,
               refusal.method == name {
                AvailabilityLog.refusal(refusal, current: presencePoll.ownAvailability)
            }
            throw Self.chatError(fromAPI: error, call: "the /api/ \(name) call")
        }
    }

    /// Your custom status after `set_custom_status`: the answer's when it
    /// carries one, otherwise what was just accepted. Written to the presence
    /// poll's memory too, or a poll agreeing with the old value would never
    /// correct it. Nothing without a `user_status` at all.
    private func emitOwnStatus(_ answer: UserStatus?, requested: MemberStatus?) {
        guard let answer else { return }
        let id = answer.userID.id.isEmpty ? calendarPoll.me : ChatKit.Member.ID(answer.userID.id)
        guard let id else { return }
        let status = answer.hasCustomStatus
            ? PresenceMapping.status(of: answer, now: Date())
            : OwnStatusRequests.sent(requested)
        presencePoll.statuses[id] = status
        emit(.statusChanged(member: id, status: status))
    }

    /// Your availability after a set call, never your custom status: the
    /// answer's when it carries both parts that decide it; otherwise, a
    /// partial answer or none at all, what was just accepted. Kept for the
    /// activity gate too (active-presence spec §3).
    private func emitAvailability(_ answer: UserStatus?, requested: Availability, call: String) {
        let availability = answer.map {
            AvailabilityMapping.availability(answering: requested, with: $0, now: Date())
        } ?? requested
        AvailabilityLog.answer(call, answer, requested: requested, shown: availability)
        presencePoll.ownAvailability = availability
        emit(.availabilityChanged(availability))
    }
}
