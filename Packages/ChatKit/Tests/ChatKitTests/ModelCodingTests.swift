import Foundation
import Testing
@testable import ChatKit

/// The domain types are the nouns of the wire format, so their shape is pinned
/// to golden files for the same reason the frames are: a renamed property is a
/// protocol change, and it should look like one in review.
@Suite("Model coding")
struct ModelCodingTests {
    @Test("every model type matches its golden file and round-trips unchanged")
    func models() throws {
        try expectWireStable(Fixture.conversation, golden: "conversation")
        try expectWireStable(Fixture.dm, golden: "conversation-dm")
        try expectWireStable(Fixture.meetChat, golden: "conversation-meetChat")
        try expectWireStable(Fixture.conversationWithReadPosition, golden: "conversation-readPosition")
        try expectWireStable(Fixture.human, golden: "member")
        try expectWireStable(Fixture.bot, golden: "member-app")
        try expectWireStable(Fixture.humanWithStatus, golden: "member-status")
        try expectWireStable(Fixture.message, golden: "message")
        try expectWireStable(Fixture.messageWithMentions, golden: "message-mentions")
        try expectWireStable(Fixture.thread, golden: "thread")
        try expectWireStable(Fixture.reaction, golden: "reaction")
        try expectWireStable(Fixture.customReaction, golden: "reaction-custom")
        try expectWireStable(Fixture.attachment, golden: "attachment")
        try expectWireStable(Fixture.imageAttachment, golden: "attachment-image")
    }

    /// Every attachment stored before the dimensions existed has no such keys.
    @Test("an attachment without dimensions decodes them as unknown")
    func attachmentWithoutDimensions() throws {
        let json = #"{"contentType":"image/png","id":"t","name":"a.png"}"#
        let attachment = try Wire.decode(Attachment.self, from: json)
        #expect(attachment.width == nil)
        #expect(attachment.height == nil)
        #expect(attachment.isImage)
    }

    @Test("an image is anything whose content type starts image/")
    func isImage() {
        #expect(Fixture.imageAttachment.isImage)
        #expect(!Fixture.attachment.isImage)
        #expect(Attachment(id: "t", name: "x", contentType: "IMAGE/JPEG").isImage)
        #expect(!Attachment(id: "t", name: "x", contentType: "").isImage)
    }

    /// Not a typealias, so these cannot be mixed up at a call site. That much is
    /// the compiler's job; what a test can check is the other half of the
    /// claim — that the wrapper is invisible on the wire.
    @Test("identifiers encode as bare strings, not as objects")
    func identifiersAreBareStrings() throws {
        #expect(try Wire.json(Box(Fixture.spaceID)) == #"{"value":"space:AAAA1111"}"#)
        #expect(try Wire.json(Box(Fixture.humanID)) == #"{"value":"users/1001"}"#)
        #expect(try Wire.json(Box(Fixture.threadID)) == #"{"value":"space:AAAA1111|topic-77"}"#)
        #expect(
            try Wire.json(Box(Fixture.messageID)) == #"{"value":"space:AAAA1111|topic-77|msg-5"}"#
        )
    }

    @Test("an identifier survives a round trip through the wire form")
    func identifierRoundTrip() throws {
        let decoded = try Wire.decode(Box<Message.ID>.self, from: #"{"value":"a|b|c"}"#)
        #expect(decoded.value == Message.ID("a|b|c"))
        #expect(decoded.value.rawValue == "a|b|c")
    }

    /// The encoder always writes these fields, so their absence means an older
    /// peer rather than a malformed frame — and every default is the assumption
    /// that claims least.
    @Test("a conversation decodes from just an id and a kind, defaulting the rest")
    func conversationDefaults() throws {
        let json = #"{"id":"dm:1","kind":"directMessage"}"#
        let conversation = try Wire.decode(Conversation.self, from: json)
        #expect(conversation.id == Conversation.ID("dm:1"))
        #expect(conversation.kind == .directMessage)
        #expect(conversation.title == nil)
        #expect(conversation.avatarURL == nil)
        #expect(conversation.lastActivity == nil)
        #expect(conversation.unreadCount == 0)
        #expect(conversation.isMuted == false)
        #expect(conversation.notificationLevel == .always)
        #expect(conversation.members.isEmpty)
        #expect(conversation.memberCount == nil)
        #expect(conversation.isThreaded == false)
        #expect(conversation.readPosition == nil)
    }

    @Test("a nil optional is omitted rather than written as null")
    func nilIsOmitted() throws {
        let json = try Wire.json(Fixture.dm)
        #expect(!json.contains("title"))
        #expect(!json.contains("null"))
        #expect(!json.contains("lastActivity"))
        #expect(!json.contains("memberCount"))
        #expect(!json.contains("readPosition"))
    }

    @Test("an explicit null decodes as absent")
    func explicitNullIsAccepted() throws {
        let json = #"{"id":"dm:1","kind":"directMessage","title":null,"lastActivity":null}"#
        let conversation = try Wire.decode(Conversation.self, from: json)
        #expect(conversation.title == nil)
        #expect(conversation.lastActivity == nil)
    }

    @Test("a timestamp that is not RFC 3339 fails loudly rather than becoming the epoch")
    func rejectsBadTimestamp() throws {
        let json = #"{"id":"dm:1","kind":"directMessage","lastActivity":"yesterday"}"#
        #expect(throws: DecodingError.self) {
            try Wire.decode(Conversation.self, from: json)
        }
    }

    @Test("a message with no reactions or attachments still encodes the empty arrays")
    func emptyCollectionsAreExplicit() throws {
        var message = Fixture.message
        message.reactions = []
        message.attachments = []
        message.editedAt = nil
        message.localID = nil
        let json = try Wire.json(message)
        #expect(json.contains(#""reactions":[]"#))
        #expect(json.contains(#""attachments":[]"#))
        #expect(!json.contains("editedAt"))
        #expect(!json.contains("localID"))
    }

    /// Written only when present, so every conversation golden recorded
    /// before it stays byte-identical. A missing key reads as `nil`, which
    /// means "nobody has said", never the epoch.
    @Test("a read position is omitted when absent and round-trips when present")
    func readPositionCoding() throws {
        #expect(try !Wire.json(Fixture.conversation).contains("readPosition"))
        let bare = try Wire.decode(Conversation.self, from: #"{"id":"dm:1","kind":"directMessage"}"#)
        #expect(bare.readPosition == nil)
        let json = try Wire.json(Fixture.conversationWithReadPosition)
        #expect(try Wire.decode(Conversation.self, from: json).readPosition == Fixture.readAt)
    }
}
