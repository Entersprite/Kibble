import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

struct ForwardedMessageMappingTests {
    /// Literal field numbers exercise the schema, not just the new Swift accessor.
    private func message(type: Int = 2, state: Int = 1, text: String = "") -> GChatBridgeCore.Message {
        var outer = GChatBridgeCore.Message()
        outer.id.messageID = "received"
        outer.id.parentID.topicID.topicID = "received-thread"
        outer.id.parentID.topicID.groupID.dmID.dmID = "destination"
        outer.creator.userID.id = "forwarder"
        outer.textBody = "My comment"
        outer.createTime = 3_000_000
        outer.replyTo = PBLiteDecoder.decode(ReplyToMessage.self, from: .array([.object([
            "1": .array([.object([
                "1": .array([.object(["4": .array([.object([
                    "2": .string("source-thread"),
                    "3": .array([.object(["3": .array([.string("source")])])])
                ])])])]),
                "2": .string("original")
            ])]),
            "2": .string("2000000"), "3": .number(.integer(Int64(state))),
            "4": .array([.string("source-sender")]),
            "5": .array([.object([
                "1": .array([.string("source-sender")]), "2": .string("Alex Example"),
                "3": .string("https://images.example.test/alex.png")
            ])]),
            "6": .string(text), "13": .string("1000000"), "15": .number(.integer(Int64(type)))
        ])])).message
        return outer
    }

    @Test func crossConversationForwardKeepsItsAuthorAndEmptySnapshotAlongsideTheComment() throws {
        let wire = message()
        #expect(wire.replyTo.referenceType == 2)
        let received = try #require(ChannelEventMapping.domainMessage(wire))
        let forwarded = try #require(received.content?.forwarded)
        #expect(received.text == "My comment")
        #expect(received.sender == Member.ID("forwarder"))
        #expect(received.content?.quote == nil)
        #expect(forwarded.source.id == ChatKit.Message.ID("original"))
        #expect(forwarded.source.conversation == Conversation.ID("dm/source"))
        #expect(forwarded.source.thread == MessageThread.ID("source-thread"))
        #expect(forwarded.source.sender == Member.ID("source-sender"))
        #expect(forwarded.source.createdAt == Date(timeIntervalSince1970: 1))
        #expect(forwarded.senderName == "Alex Example")
        #expect(forwarded.senderAvatarURL?.absoluteString == "https://images.example.test/alex.png")
        #expect(forwarded.source.text.isEmpty)
    }

    @Test func snapshotFormattingAndDeletionUseTheSharedContentMapping() throws {
        var wire = message(text: "Original body")
        var annotation = Annotation()
        annotation.type = .formatData
        annotation.startIndex = 0
        annotation.length = 8
        annotation.formatMetadata.formatType = .bold
        wire.replyTo.annotations = [annotation]
        let received = try #require(ChannelEventMapping.domainMessage(wire))
        let forwarded = try #require(received.content?.forwarded)
        #expect(forwarded.source.text == "Original body")
        #expect(forwarded.formatting == [MessageFormat(style: "bold", start: 0, length: 8)])
        let deleted = try #require(ChannelEventMapping.domainMessage(message(state: 2, text: "Old body")))
        #expect(deleted.content?.forwarded?.source.isDeleted == true)
        #expect(deleted.content?.forwarded?.source.text.isEmpty == true)
        #expect(deleted.text == "My comment")
    }

    /// A forward whose reference names no source still draws its author and
    /// text; the snapshot's address is left empty, so nothing opens it.
    @Test func forwardWithoutASourceAddressKeepsItsAuthorAndText() throws {
        var wire = message(text: "Original body")
        wire.replyTo = PBLiteDecoder.decode(ReplyToMessage.self, from: .array([.object([
            "5": .array([.object(["1": .array([.string("source-sender")]), "2": .string("Alex Example")])]),
            "6": .string("Original body"), "13": .string("1000000"), "15": .number(.integer(2))
        ])])).message
        let received = try #require(ChannelEventMapping.domainMessage(wire))
        let forwarded = try #require(received.content?.forwarded)
        #expect(forwarded.source.text == "Original body")
        #expect(forwarded.source.sender == Member.ID("source-sender"))
        #expect(forwarded.senderName == "Alex Example")
        #expect(forwarded.source.id.rawValue.isEmpty)
        #expect(forwarded.source.conversation.rawValue.isEmpty)
        #expect(forwarded.source.thread.rawValue.isEmpty)
        #expect(received.content?.quote == nil)
    }

    /// No quote crosses conversations, so an untyped reference to another
    /// conversation is a forward.
    @Test func untypedReferenceToAnotherConversationIsAForward() throws {
        var wire = message(text: "Original body")
        wire.replyTo.clearReferenceType()
        #expect(!wire.replyTo.hasReferenceType)
        let received = try #require(ChannelEventMapping.domainMessage(wire))
        #expect(received.content?.forwarded?.source.text == "Original body")
        #expect(received.content?.quote == nil)
        wire.replyTo.id.parentID.topicID.groupID = wire.id.parentID.topicID.groupID
        let quoted = try #require(ChannelEventMapping.domainMessage(wire))
        #expect(quoted.content?.forwarded == nil)
        #expect(quoted.content?.quote?.text == "Original body")
    }

    /// The author is whichever of the nested profile, the bare id and the
    /// second profile the reference carries, for quotes as for forwards.
    @Test func authorComesFromWhicheverFieldTheReferenceCarries() throws {
        var bare = message(text: "Body")
        bare.replyTo.clearSender()
        #expect(ForwardedMessageMapping.author(of: bare.replyTo).id == "source-sender")
        var nested = message(text: "Body")
        nested.replyTo.clearSenderID()
        #expect(ForwardedMessageMapping.author(of: nested.replyTo).id == "source-sender")
        #expect(ForwardedMessageMapping.author(of: nested.replyTo).name == "Alex Example")
        var second = message(text: "Body")
        second.replyTo.clearSender()
        second.replyTo.clearSenderID()
        second.replyTo.senderAgain.userID.id = "updater"
        second.replyTo.senderAgain.name = "Sam Example"
        #expect(ForwardedMessageMapping.author(of: second.replyTo).id == "updater")
        #expect(ForwardedMessageMapping.author(of: second.replyTo).name == "Sam Example")
        var quote = message(type: 1, text: "Quoted")
        quote.replyTo.id.parentID.topicID.groupID = quote.id.parentID.topicID.groupID
        quote.replyTo.clearSenderID()
        let quoted = try #require(ChannelEventMapping.domainMessage(quote)?.content?.quote)
        #expect(quoted.sender == Member.ID("source-sender"))
    }

    /// A quote names its author only by id, so the author is looked up
    /// beside the sender, as a forward's source author is.
    @Test func quotedAndForwardedAuthorsAreLookedUp() throws {
        let forward = try #require(ChannelEventMapping.domainMessage(message()))
        #expect(LocalBridgeBackend.memberIDs(in: .messageReceived(forward)) == [
            Member.ID("forwarder"), Member.ID("source-sender")
        ])
        var wire = message(type: 1, text: "Quoted")
        wire.replyTo.id.parentID.topicID.groupID = wire.id.parentID.topicID.groupID
        let quoted = try #require(ChannelEventMapping.domainMessage(wire))
        #expect(LocalBridgeBackend.referencedMembers(of: quoted) == [
            Member.ID("forwarder"), Member.ID("source-sender")
        ])
    }

    @Test func quoteAndUnknownReferencesAreNeverMisclassifiedAsForwards() throws {
        for type in [0, 1, 3, 99] {
            var wire = message(type: type, text: "Quoted body")
            wire.replyTo.id.parentID.topicID.groupID = wire.id.parentID.topicID.groupID
            let received = try #require(ChannelEventMapping.domainMessage(wire))
            #expect(received.content?.forwarded == nil)
            #expect((received.content?.quote != nil) == (type == 0 || type == 1))
        }
    }
}
