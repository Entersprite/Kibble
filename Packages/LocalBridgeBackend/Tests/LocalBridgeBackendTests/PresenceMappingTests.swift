import ChatKit
import Foundation
import GChatBridgeCore
import SwiftProtobuf
import Testing
@testable import LocalBridgeBackend

/// `GetUserPresenceResponse` becoming `[Member.ID: ChatKit.Presence]`.
///
/// Typed `SwiftProtobuf` fixtures, the way `MemberMappingTests` builds its
/// own: `get_user_presence` has never been sent by this implementation, so
/// every mapping here is a claim about the vendored proto's field numbers
/// (identical in all three references), not about a response observed on the
/// wire.
struct PresenceMappingTests {
    private func entry(
        _ id: String,
        presence: GChatBridgeCore.Presence? = nil,
        dnd: DndState_State? = nil,
        statusDnd: DndSettings.DndState_State? = nil
    ) -> UserPresence {
        var entry = UserPresence()
        entry.userID.id = id
        if let presence {
            entry.presence = presence
        }
        if let dnd {
            entry.dndState = dnd
        }
        if let statusDnd {
            entry.userStatus.dndSettings.dndState = statusDnd
        }
        return entry
    }

    private func map(_ entries: [UserPresence]) -> [ChatKit.Member.ID: ChatKit.Presence] {
        var response = GetUserPresenceResponse()
        response.userPresences = entries
        return PresenceMapping.map(response)
    }

    @Test func activeAndInactiveMapToTheirDomainCases() {
        let mapped = map([entry("u-1", presence: .active), entry("u-2", presence: .inactive)])
        #expect(mapped == [ChatKit.Member.ID("u-1"): .active, ChatKit.Member.ID("u-2"): .inactive])
    }

    /// Do not disturb wins over active: someone at their desk who asked not
    /// to be disturbed is shown as that, not as green.
    @Test func doNotDisturbWinsOverActive() {
        let mapped = map([entry("u-1", presence: .active, dnd: .dnd)])
        #expect(mapped == [ChatKit.Member.ID("u-1"): .doNotDisturb])
    }

    /// DND can arrive inside `user_status.dnd_settings` rather than at the
    /// top level - that is where `USER_STATUS_UPDATED_EVENT` carries it, and
    /// which of the two a poll fills is `[Verify]`. Either is believed.
    @Test func doNotDisturbInsideTheUserStatusCountsToo() {
        let mapped = map([entry("u-1", presence: .inactive, statusDnd: .dnd)])
        #expect(mapped == [ChatKit.Member.ID("u-1"): .doNotDisturb])
    }

    @Test func availableIsNotDoNotDisturb() {
        let mapped = map([entry("u-1", presence: .active, dnd: .available, statusDnd: .available)])
        #expect(mapped == [ChatKit.Member.ID("u-1"): .active])
    }

    /// The wire's other named values are real answers this seam does not
    /// model, so they pass through as `.unknown(raw)` and draw nothing.
    @Test func theOtherNamedValuesPassThroughAsUnknown() {
        let mapped = map([
            entry("u-1", presence: .undefinedPresence),
            entry("u-2", presence: .unknown),
            entry("u-3", presence: .sharingDisabled)
        ])
        #expect(mapped == [
            ChatKit.Member.ID("u-1"): .unknown("UNDEFINED_PRESENCE"),
            ChatKit.Member.ID("u-2"): .unknown("UNKNOWN"),
            ChatKit.Member.ID("u-3"): .unknown("SHARING_DISABLED")
        ])
    }

    /// A value outside the vendored proto2 enum clears the presence bit and
    /// lands in `unknownFields` (`CLAUDE.md`, the typed decode rule). Read as
    /// absence, it would be "nobody told us"; the byte walk says otherwise.
    @Test func aValueOutsideTheEnumIsReadFromTheBytes() throws {
        // Field 1 (user_id, length-delimited) then field 2 (presence) = 9.
        var userID = UserId()
        userID.id = "u-1"
        var bytes = Data([0x0A])
        let idBytes: Data = try userID.serializedBytes()
        bytes.append(UInt8(idBytes.count))
        bytes.append(idBytes)
        bytes.append(contentsOf: [0x10, 0x09])
        let decoded = try UserPresence(serializedBytes: bytes)
        // Positive control: this really is the trap, not a typed value.
        #expect(!decoded.hasPresence)

        #expect(map([decoded]) == [ChatKit.Member.ID("u-1"): .unknown("presence=9")])
    }

    /// Nothing about presence at all is "nobody told us": no entry, so the
    /// store keeps `nil` rather than an invented state.
    @Test func anEntryWithNoPresenceAndNoDndIsLeftOut() {
        #expect(map([entry("u-1")]).isEmpty)
    }

    @Test func anEntryWithNoIdIsSkipped() {
        #expect(map([entry("", presence: .active)]).isEmpty)
    }
}
