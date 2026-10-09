import ChatKit
import Foundation
import Testing
@testable import DesignSystem

/// One edit at a time across both composers (threads spec §4.3, ruling 4): a
/// request belongs to the composer whose messages hold its message.
@MainActor
struct ThreadEditRoutingTests {
    private func message(_ id: String, isReply: Bool = false) -> Message {
        Message(
            id: Message.ID(id), conversationID: Conversation.ID("space/s-1"),
            threadID: MessageThread.ID("t-1"), sender: Member.ID("u-me"), text: id,
            createdAt: Date(timeIntervalSince1970: 0), isReply: isReply
        )
    }

    @Test func aTranscriptMessageBelongsToTheTranscript() {
        #expect(ThreadEditRouting.owner(
            of: Message.ID("top"), transcript: [message("top")], panel: [message("reply")]
        ) == .transcript)
    }

    @Test func aReplyBelongsToThePanel() {
        #expect(ThreadEditRouting.owner(
            of: Message.ID("reply"), transcript: [message("top")], panel: [message("reply")]
        ) == .panel)
    }

    /// A thread's first message is in both lists. Its edit happens in the
    /// transcript, where it was written.
    @Test func theFirstMessageBelongsToTheTranscript() {
        #expect(ThreadEditRouting.owner(
            of: Message.ID("top"), transcript: [message("top")], panel: [message("top"), message("reply")]
        ) == .transcript)
    }

    @Test func aMessageInNeitherBelongsToNoOne() {
        #expect(ThreadEditRouting.owner(of: Message.ID("gone"), transcript: [], panel: []) == nil)
    }

    /// A menu's Edit… and Up arrow reach a composer only while the other is
    /// not editing: a request routed to one composer does not end the
    /// other's edit, so offering it would put both in edit mode.
    @Test func whileOneComposerEditsTheOtherOffersNoEdit() {
        #expect(!ThreadEditRouting.offersEdit(in: .transcript, editing: .panel))
        #expect(!ThreadEditRouting.offersEdit(in: .panel, editing: .transcript))
    }

    /// Switching an edit within one composer is kept, as before threads.
    @Test func theEditingComposerKeepsOfferingEdit() {
        #expect(ThreadEditRouting.offersEdit(in: .panel, editing: .panel))
        #expect(ThreadEditRouting.offersEdit(in: .transcript, editing: .transcript))
    }

    @Test func withNothingEditedEveryComposerOffersEdit() {
        #expect(ThreadEditRouting.offersEdit(in: .transcript, editing: nil))
        #expect(ThreadEditRouting.offersEdit(in: .panel, editing: nil))
    }

    /// Dropped files go to a composer only while it is not editing: an edit
    /// never carries files (edit spec §5). The other composer's edit leaves
    /// it free. An edit whose message neither list holds (deleted meanwhile)
    /// still has its composer in edit mode, so neither takes files.
    @Test func aComposerTakesDropsOnlyWhileItIsNotEditing() {
        struct Row {
            let composer: ThreadEditRouting.Owner
            let owner: ThreadEditRouting.Owner?
            let anyEdit: Bool
            let takes: Bool
        }
        let rows = [
            Row(composer: .transcript, owner: nil, anyEdit: false, takes: true),
            Row(composer: .panel, owner: nil, anyEdit: false, takes: true),
            Row(composer: .transcript, owner: .transcript, anyEdit: true, takes: false),
            Row(composer: .panel, owner: .panel, anyEdit: true, takes: false),
            Row(composer: .transcript, owner: .panel, anyEdit: true, takes: true),
            Row(composer: .panel, owner: .transcript, anyEdit: true, takes: true),
            Row(composer: .transcript, owner: nil, anyEdit: true, takes: false),
            Row(composer: .panel, owner: nil, anyEdit: true, takes: false)
        ]
        for row in rows {
            let result = ThreadEditRouting.takesDrops(
                in: row.composer,
                editing: row.owner,
                anyEdit: row.anyEdit
            )
            #expect(result == row.takes, "\(row.composer) \(String(describing: row.owner)) \(row.anyEdit)")
        }
    }

    /// The panel's composer goes with its thread and never says so: its edit
    /// is forgotten when the panel changes, so a reopened thread does not
    /// begin it again. The transcript's edit stays.
    @Test func onlyTheTranscriptsEditOutlivesAPanelChange() {
        let transcript = [message("top")]
        #expect(ThreadEditRouting.survivesPanelChange(Message.ID("top"), transcript: transcript))
        #expect(!ThreadEditRouting.survivesPanelChange(Message.ID("reply"), transcript: transcript))
    }

    /// The panel is the thread already: its first message offers no "Reply
    /// in Thread", which the transcript's copy of it does.
    @Test func thePanelOffersNoReplyInThread() {
        let space = Conversation(
            id: Conversation.ID("space/s-1"), kind: .space, title: "Deploys", repliesEnabled: true
        )
        let first = message("top")
        let window = ChatWindow(
            state: ChatSceneState(
                conversations: [space], me: Member.ID("u-me"), selected: space.id, messages: [first],
                threads: ThreadSceneState(panel: ThreadPanelState(
                    thread: MessageThread(
                        id: MessageThread.ID("t-1"),
                        conversationID: space.id,
                        replyCount: 1
                    ),
                    conversationTitle: "Deploys", messages: [first]
                ))
            ),
            actions: ChatSceneActions(threads: ThreadActions(
                open: { _ in }, close: {}, sendReply: { _ in }, setFollowed: { _ in },
                markUnread: { _ in }, showList: {}, openItem: { _, _ in }
            ))
        )
        #expect(window.ownHandlers?.items(for: first)?.replyInThread != nil)
        #expect(window.panelHandlers(for: first)?.items(for: first)?.replyInThread == nil)
    }
}
