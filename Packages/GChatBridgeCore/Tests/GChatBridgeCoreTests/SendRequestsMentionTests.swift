import Foundation
import Testing
@testable import GChatBridgeCore

/// The mention Chat on the web sends (`findings.md` §56.2): type 6, a UTF-16
/// span, and `user_mention_metadata { id, type MENTION, invitee_info { user_id,
/// email } }`, with **no** `display_name` and **no** `chip_render_type`.
/// That is not mautrix's shape (`gc_message.py:95-110`), on purpose.
struct SendRequestsMentionTests {
    @Test func aUserMentionIsTheWebClientsShape() {
        let annotation = SendRequests.mentionAnnotation(
            userID: "u-1", email: "a@example.invalid", start: 5, length: 13
        )
        #expect(annotation.type == .userMention)
        #expect(annotation.startIndex == 5)
        #expect(annotation.length == 13)
        #expect(!annotation.hasChipRenderType)
        let metadata = annotation.userMentionMetadata
        #expect(metadata.type == .mention)
        #expect(metadata.id.id == "u-1")
        #expect(!metadata.hasDisplayName)
        #expect(metadata.inviteeInfo.userID.id == "u-1")
        #expect(metadata.inviteeInfo.email == "a@example.invalid")
    }

    @Test func anUnknownEmailOmitsInviteeInfo() {
        let annotation = SendRequests.mentionAnnotation(userID: "u-1", email: nil, start: 0, length: 4)
        #expect(!annotation.userMentionMetadata.hasInviteeInfo)
        #expect(annotation.userMentionMetadata.id.id == "u-1")
    }

    @Test func allIsMentionAllWithNoID() {
        let annotation = SendRequests.mentionAllAnnotation(start: 0, length: 4)
        #expect(annotation.type == .userMention)
        #expect(annotation.userMentionMetadata.type == .mentionAll)
        #expect(!annotation.userMentionMetadata.hasID)
        #expect(annotation.startIndex == 0)
        #expect(annotation.length == 4)
    }

    @Test func eachTypeIsOnTheWire() {
        let invite = SendRequests.mentionAnnotation(
            userID: "u-1",
            email: nil,
            start: 0,
            length: 4,
            type: .invite
        )
        let without = SendRequests.mentionAnnotation(
            userID: "u-1", email: nil, start: 0, length: 4, type: .mentionWithoutAdding
        )
        #expect(invite.userMentionMetadata.type.rawValue == 1)
        #expect(without.userMentionMetadata.type.rawValue == 6)
        #expect(SendRequests.mentionAnnotation(userID: "u-1", email: nil, start: 0, length: 4)
            .userMentionMetadata.type == .mention)
    }
}
