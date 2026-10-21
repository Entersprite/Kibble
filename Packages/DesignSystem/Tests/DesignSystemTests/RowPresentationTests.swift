import ChatKit
import Foundation
import Testing
@testable import DesignSystem

struct RowPresentationTests {
    private let me = Member.ID("me")
    private let sender = Member.ID("sender")
    private let replier = Member.ID("replier")
    private let other = Member.ID("other")
    private let conversation = Conversation.ID("space/example")

    private var message: Message {
        Message(
            id: Message.ID("message"), conversationID: conversation,
            threadID: MessageThread.ID("thread"), sender: sender, text: "Hello",
            createdAt: Date(timeIntervalSince1970: 100),
            attachments: [Attachment(id: "file", name: "file.txt", contentType: "text/plain")]
        )
    }

    private var scene: ChatSceneState {
        ChatSceneState(
            directory: [
                sender: Member(id: sender, kind: .human, displayName: "Alex"),
                replier: Member(id: replier, kind: .human, displayName: "Sam"),
                other: Member(id: other, kind: .human, displayName: "Taylor")
            ],
            me: me,
            messages: [message],
            connection: .connected,
            threads: ThreadSceneState(summaries: [message.threadID: MessageThread(
                id: message.threadID, conversationID: conversation, replyCount: 2,
                recentRepliers: [replier]
            )])
        )
    }

    @Test func backgroundUpdatesDoNotInvalidateMessageRows() {
        let original = scene
        var updated = original
        updated.directory[other]?.displayName = "New name"
        updated.directory[sender]?.presence = .active
        updated.directory[replier]?.status = MemberStatus(text: "Busy")
        updated.directory[sender]?.calendar = CalendarSchedule(entries: [], validUntil: .distantFuture)
        updated.typing = [other]
        updated.unreadMentionCount = 8
        updated.threads.unreadCount = 3
        updated.downloads["unrelated-file"] = .done
        updated.messages.append(message)

        #expect(MessageRowState(message: message, scene: original)
            == MessageRowState(message: message, scene: updated))
    }

    /// A row that draws its sender's picture (a group's last message, a
    /// thread reply) shows their presence, and follows it; nobody else's
    /// presence, status or calendar touches it, and a row with no picture
    /// ignores presence as before.
    @Test func aRowWithTheSendersPictureFollowsOnlyTheirPresence() {
        var updated = scene
        let original = MessageRowState(message: message, scene: updated, badgesSender: true)
        #expect(original.senderPresence == nil)
        updated.directory[other]?.presence = .active
        updated.directory[sender]?.status = MemberStatus(text: "Busy")
        #expect(MessageRowState(message: message, scene: updated, badgesSender: true) == original)

        updated.directory[sender]?.presence = .active
        let badged = MessageRowState(message: message, scene: updated, badgesSender: true)
        #expect(badged.senderPresence == .active)
        #expect(badged != original)
        #expect(MessageRowState(message: message, scene: updated).senderPresence == nil)

        // Not while disconnected: a dot is a claim about now.
        updated.connection = .connecting
        #expect(MessageRowState(message: message, scene: updated, badgesSender: true).senderPresence == nil)
    }

    @Test func messageRowsStillReceiveNamesPhotosRepliesAndDownloads() {
        var updated = scene
        let original = MessageRowState(message: message, scene: updated)
        updated.directory[sender]?.displayName = "Changed sender"
        #expect(MessageRowState(message: message, scene: updated) != original)
        updated = scene
        updated.directory[replier]?.avatarURL = URL(string: "https://example.com/photo.png")
        #expect(MessageRowState(message: message, scene: updated) != original)
        updated = scene
        updated.threads.summaries[message.threadID]?.replyCount = 4
        #expect(MessageRowState(message: message, scene: updated) != original)
        updated = scene
        updated.downloads["file"] = .done
        #expect(MessageRowState(message: message, scene: updated).downloads == ["file": .done])
        #expect(MessageRowState(message: message, scene: updated, downloads: [:]).downloads.isEmpty)
        #expect(MessageRowState(message: message, scene: updated, downloads: ["file": .failed("Retry")])
            .downloads == ["file": .failed("Retry")])
    }

    @Test func threadPanelRowsIgnoreTranscriptThreadMarks() {
        let original = MessageRowState(message: message, scene: scene, showsThread: false)
        var updated = scene
        updated.threads.summaries[message.threadID]?.replyCount = 10
        updated.directory[replier]?.displayName = "Changed replier"
        #expect(original.thread == nil)
        #expect(original.directory.keys.sorted { $0.rawValue < $1.rawValue } == [sender])
        #expect(MessageRowState(message: message, scene: updated, showsThread: false) == original)
    }

    @Test func sidebarRowsIgnoreOtherConversationsAndTranscriptUpdates() {
        let direct = Conversation(id: conversation, kind: .directMessage, members: [me, sender])
        let original = ConversationRowState(conversation: direct, scene: scene)
        var updated = scene
        updated.messages.append(message)
        updated.directory[other]?.presence = .active
        updated.threads.unreadConversations = [Conversation.ID("space/other")]
        updated.dimmed = [Conversation.ID("space/other")]
        #expect(ConversationRowState(conversation: direct, scene: updated) == original)

        updated.directory[sender]?.presence = .active
        #expect(ConversationRowState(conversation: direct, scene: updated) != original)
        updated.threads.unreadConversations.insert(conversation)
        #expect(!ConversationRowState(conversation: direct, scene: updated).showsUnread)
        var unread = direct
        unread.hasUnread = true
        #expect(ConversationRowState(conversation: unread, scene: updated).showsUnread)
        updated.unreadHidden.insert(conversation)
        #expect(!ConversationRowState(conversation: unread, scene: updated).showsUnread)
        updated.dimmed.insert(conversation)
        updated.muted.insert(conversation)
        let muted = ConversationRowState(conversation: direct, scene: updated)
        #expect(muted.dimmed && muted.muted)
    }

    @Test func avatarProjectionPreservesUnresolvedPeopleAndProfileChanges() {
        let ids = [sender, replier, other]
        let missing: [Member.ID: Member] = [:]
        #expect(RowDirectory.avatars(ids, in: missing).isEmpty)
        let original = RowDirectory.avatars(ids, in: scene.directory)
        var updated = scene.directory
        updated[sender]?.presence = .active
        #expect(RowDirectory.avatars(ids, in: updated) == original)
        updated[sender]?.displayName = "Resolved name"
        #expect(RowDirectory.avatars(ids, in: updated) != original)
    }

    @Test func aReadSpaceWithUnreadFollowedRepliesKeepsItsSpaceDotClear() {
        let readSpace = Conversation(
            id: conversation, kind: .space, hasUnread: false, hasUnreadThread: true
        )
        var state = scene
        state.threads.unreadCount = 1
        state.threads.unreadConversations = [conversation]
        state.threads.summaries[message.threadID]?.hasUnread = true

        #expect(!ConversationRowState(conversation: readSpace, scene: state).showsUnread)
        #expect(ThreadsPresentation.badge(unread: state.threads.unreadCount) == "1")
        #expect(MessageRowState(message: message, scene: state).thread?.hasUnread == true)

        var unreadSpace = readSpace
        unreadSpace.hasUnread = true
        #expect(ConversationRowState(conversation: unreadSpace, scene: state).showsUnread)
        state.unreadHidden.insert(conversation)
        #expect(!ConversationRowState(conversation: unreadSpace, scene: state).showsUnread)
    }
}
