import ChatKit
import Foundation
import Testing
@testable import DesignSystem

/// The Threads row, the sidebar's dot, and the list's items.
struct ThreadsPresentationTests {
    private func conversation(unread: Bool, threads: Bool) -> Conversation {
        Conversation(
            id: Conversation.ID("space/s-1"), kind: .space, title: "Deploys",
            hasUnread: unread, hasUnreadThread: threads
        )
    }

    private func root(in conversation: Conversation.ID) -> Message {
        Message(
            id: Message.ID("m-1"), conversationID: conversation,
            threadID: MessageThread.ID("t-1"), sender: Member.ID("u-2"), text: "deploy?",
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }

    @Test func theBadgeIsThePlainCountAndNothingAtZero() {
        #expect(ThreadsPresentation.badge(unread: 0) == nil)
        #expect(ThreadsPresentation.badge(unread: 3) == "3")
    }

    /// The dot shows for a top-level unread and for activity in a followed
    /// thread alike (owner, session 58): no thread symbol.
    @Test func theDotShowsForTopLevelOrFollowedThreadActivity() {
        let space = conversation(unread: false, threads: false)
        #expect(ThreadsPresentation.showsUnread(
            conversation(unread: true, threads: false), hidden: false, unreadThreads: []
        ))
        #expect(ThreadsPresentation.showsUnread(space, hidden: false, unreadThreads: [space.id]))
        #expect(!ThreadsPresentation.showsUnread(space, hidden: false, unreadThreads: []))
    }

    /// Followed threads only: the server's flag, whose scope is unmeasured,
    /// shows no dot of its own (session 58, `[Verify]` in `findings.md` §64).
    @Test func theServersThreadFlagAloneShowsNoDot() {
        #expect(!ThreadsPresentation.showsUnread(
            conversation(unread: false, threads: true), hidden: false, unreadThreads: []
        ))
    }

    /// Meet chats send field 27 false (§63.2): no "Reply in Thread" there, and
    /// nothing before a conversation is selected (Review Focus 2).
    @Test func onlyAConversationWithRepliesOffersThem() {
        let space = conversation(unread: false, threads: false)
        var withReplies = space
        withReplies.repliesEnabled = true
        let meet = Conversation(id: Conversation.ID("space/m-1"), kind: .meetChat, title: "Standup")
        #expect(ThreadsPresentation.offersReplies(in: withReplies))
        #expect(!ThreadsPresentation.offersReplies(in: space))
        #expect(!ThreadsPresentation.offersReplies(in: meet))
        #expect(!ThreadsPresentation.offersReplies(in: nil))
    }

    /// A rule that hides unread hides thread activity too.
    @Test func aHiddenConversationShowsNoDot() {
        let space = conversation(unread: true, threads: false)
        #expect(!ThreadsPresentation.showsUnread(space, hidden: true, unreadThreads: [space.id]))
    }

    /// The Threads row is chosen as the Mentions row is: no conversation is.
    @Test func theThreadsRowIsTheSidebarSelection() {
        let listing = ChatSceneState(threads: ThreadSceneState(showingList: true))
        #expect(listing.sidebarSelection == .threads)
        #expect(ChatSceneState(selected: Conversation.ID("space/s-1")).sidebarSelection
            == .conversation(Conversation.ID("space/s-1")))
    }

    @Test func anItemNamesItsConversationAndSender() {
        let thread = MessageThread(
            id: MessageThread.ID("t-1"), conversationID: Conversation.ID("space/s-1"), replyCount: 3
        )
        let directory = [Member.ID("u-2"): Member(id: Member.ID("u-2"), kind: .human, displayName: "Alex")]
        let item = ThreadListItem(
            root: root(in: Conversation.ID("space/s-1")), thread: thread,
            conversation: conversation(unread: false, threads: false), directory: directory, me: nil
        )
        #expect(item.id == ThreadListItem.Key(
            conversation: Conversation.ID("space/s-1"), thread: MessageThread.ID("t-1")
        ))
        #expect(item.conversationTitle == "Deploys")
        #expect(item.senderName == "Alex")
    }

    /// A topic id is unique only within its conversation (ruling 8), so two
    /// conversations' threads with one id are two rows, never one.
    @Test func twoConversationsMayShareAThreadID() {
        let other = Conversation(id: Conversation.ID("space/s-2"), kind: .space, title: "Builds")
        let items = [conversation(unread: false, threads: false), other].map { conversation in
            ThreadListItem(
                root: root(in: conversation.id),
                thread: MessageThread(
                    id: MessageThread.ID("t-1"),
                    conversationID: conversation.id,
                    replyCount: 2
                ),
                conversation: conversation, directory: [:], me: nil
            )
        }
        #expect(items[0].id != items[1].id)
    }

    @Test func aPanelSplitsItsFirstMessageFromItsReplies() {
        func message(_ id: String, reply: Bool) -> Message {
            Message(
                id: Message.ID(id), conversationID: Conversation.ID("space/s-1"),
                threadID: MessageThread.ID("t-1"), sender: Member.ID("u-2"), text: id,
                createdAt: Date(timeIntervalSince1970: 0), isReply: reply
            )
        }
        let panel = ThreadPanelState(
            thread: MessageThread(id: MessageThread.ID("t-1"), conversationID: Conversation.ID("space/s-1")),
            conversationTitle: "Deploys",
            messages: [
                message("first", reply: false),
                message("r-1", reply: true),
                message("r-2", reply: true)
            ],
            scrollTarget: nil, followPending: false
        )
        #expect(panel.firstMessage?.id == Message.ID("first"))
        #expect(panel.replies.map(\.id) == [Message.ID("r-1"), Message.ID("r-2")])
    }
}
