import ChatKit
import Foundation
import Testing
@testable import DesignSystem

/// Which messages offer Edit… and Delete… (edit spec §5). One rule for both
/// menus and the Up arrow, so they cannot disagree.
struct OwnMessageRuleTests {
    private static let me = Member.ID("u-me")

    private static func message(
        id: String = "m-1", sender: Member.ID = me, text: String = "hi", isDeleted: Bool = false,
        attachments: [ChatKit.Attachment] = []
    ) -> Message {
        Message(
            id: Message.ID(id), conversationID: Conversation.ID("space/s-1"),
            threadID: MessageThread.ID("t-1"),
            sender: sender, text: text, createdAt: Date(timeIntervalSince1970: 0), isDeleted: isDeleted,
            attachments: attachments
        )
    }

    @Test func myMessageOffersBoth() {
        #expect(OwnMessageRule.canDelete(Self.message(), me: Self.me))
        #expect(OwnMessageRule.canEdit(Self.message(), me: Self.me))
    }

    @Test func someoneElsesOffersNeither() {
        let theirs = Self.message(sender: Member.ID("u-other"))
        #expect(!OwnMessageRule.canDelete(theirs, me: Self.me))
        #expect(!OwnMessageRule.canEdit(theirs, me: Self.me))
    }

    /// Guard: with nobody identified yet, nothing is "mine".
    @Test func withNoMeNothingIsMine() {
        #expect(!OwnMessageRule.canDelete(Self.message(), me: nil))
    }

    @Test func aDeletedOrSendingMessageOffersNeither() {
        #expect(!OwnMessageRule.canDelete(Self.message(isDeleted: true), me: Self.me))
        #expect(!OwnMessageRule.canDelete(Self.message(id: "local/x"), me: Self.me))
    }

    /// Edit spec §5: an attachment's message, or one with no text, can be
    /// deleted and not edited, until the probe's successor measures it.
    @Test func anAttachmentOrNoTextOffersDeleteOnly() {
        let file = ChatKit.Attachment(id: "a-1", name: "f.png", contentType: "image/png")
        for message in [Self.message(attachments: [file]), Self.message(text: "")] {
            #expect(OwnMessageRule.canDelete(message, me: Self.me))
            #expect(!OwnMessageRule.canEdit(message, me: Self.me))
        }
    }

    @Test func theNewestEditableSkipsWhatCannotBeEdited() {
        let messages = [
            Self.message(id: "m-1", text: "old"),
            Self.message(id: "m-2", text: "mine"),
            Self.message(id: "m-3", sender: Member.ID("u-other")),
            Self.message(id: "local/4")
        ]
        #expect(OwnMessageRule.newestEditable(in: messages, me: Self.me)?.id == Message.ID("m-2"))
    }
}
