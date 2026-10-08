import ChatKit
import Foundation
import GChatBridgeCore

/// `.setStatus` and `.setAvailability` (set-your-status spec §3), and why
/// `capabilities.canSetStatus` is true. Its own file because
/// `LocalBridgeBackend.swift` is at swiftlint's `file_length`.
///
/// Each answer carries your updated `UserStatus`, which is emitted as soon
/// as it arrives rather than waiting for the presence poll. A refused call
/// throws, and `SyncEngine.submit` records it for the banner; nothing was
/// changed locally, so nothing springs back. The shapes are `[Verify]` until
/// the owner's first live use.
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
            emitOwn(response.hasUserStatus ? response.userStatus : nil)
        case let .setAvailability(availability):
            try await setAvailability(availability, using: apiClient)
        default:
            break
        }
    }

    /// Automatic and away set presence sharing, then end Do not disturb; each
    /// answer is emitted, so a failed second call still shows the first.
    private func setAvailability(_ availability: Availability, using api: ProtoAPIClient) async throws {
        switch availability {
        case .automatic, .away:
            let sharing = availability == .automatic
            let shared = try await call("set_presence_shared") {
                try await api.call(.setPresenceShared, OwnStatusRequests.setPresenceShared(sharing))
            }
            emitOwn(shared.hasUserStatus ? shared.userStatus : nil)
            let dnd = try await call("set_dnd_duration") {
                try await api.call(.setDndDuration, OwnStatusRequests.doNotDisturbOff())
            }
            emitOwn(dnd.hasUserStatus ? dnd.userStatus : nil)
        case let .doNotDisturb(end):
            let dnd = try await call("set_dnd_duration") {
                try await api.call(.setDndDuration, OwnStatusRequests.doNotDisturb(until: end))
            }
            emitOwn(dnd.hasUserStatus ? dnd.userStatus : nil)
        case let .unknown(raw):
            throw ChatError.unsupported(capability: raw)
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

    /// Your custom status and availability, from an answer's `UserStatus`.
    private func emitOwn(_ status: UserStatus?) {
        guard let status else { return }
        let now = Date()
        let id = status.userID.id.isEmpty ? calendarPoll.me : ChatKit.Member.ID(status.userID.id)
        if let id {
            emit(.statusChanged(member: id, status: PresenceMapping.status(of: status, now: now)))
        }
        emit(.availabilityChanged(AvailabilityMapping.availability(of: status, now: now)))
    }
}
