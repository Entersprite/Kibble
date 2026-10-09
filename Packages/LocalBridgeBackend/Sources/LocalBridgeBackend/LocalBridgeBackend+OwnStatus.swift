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

    /// Automatic and away end Do not disturb, then set presence sharing; each
    /// answer is emitted, so a failed second call still shows the first.
    ///
    /// **Do not disturb first.** Sent after presence sharing, Away never
    /// stuck: the owner picked it, Google answered at once with presence
    /// shared, and Chat on the web showed him active (session 62). Ending Do
    /// not disturb is suspected of sharing presence again, so presence
    /// sharing goes last and has the last word. `[Verify]` live.
    private func setAvailability(_ availability: Availability, using api: ProtoAPIClient) async throws {
        switch availability {
        case .automatic, .away:
            let dnd = try await call("set_dnd_duration") {
                try await api.call(.setDndDuration, OwnStatusRequests.doNotDisturbOff())
            }
            emitAvailability(
                dnd.hasUserStatus ? dnd.userStatus : nil,
                requested: availability,
                call: "set_dnd_duration"
            )
            let sharing = availability == .automatic
            let shared = try await call("set_presence_shared") {
                try await api.call(.setPresenceShared, OwnStatusRequests.setPresenceShared(sharing))
            }
            emitAvailability(
                shared.hasUserStatus ? shared.userStatus : nil, requested: availability,
                call: "set_presence_shared"
            )
        case let .doNotDisturb(end):
            let dnd = try await call("set_dnd_duration") {
                try await api.call(.setDndDuration, OwnStatusRequests.doNotDisturb(until: end))
            }
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

    /// One `/api/` call, its failure named for the banner.
    private func call<Response>(
        _ name: String,
        _ body: () async throws -> Response
    ) async throws -> Response {
        do {
            return try await body()
        } catch {
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
