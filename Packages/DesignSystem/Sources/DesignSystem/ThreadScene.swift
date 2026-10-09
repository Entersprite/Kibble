import ChatKit
import Foundation

/// Everything the window draws about threads (threads spec §5), as one value
/// on `ChatSceneState`, so the scene grows by one property.
public struct ThreadSceneState: Sendable, Equatable {
    /// The selected conversation's threads, for the marks under its messages.
    public var summaries: [MessageThread.ID: MessageThread]
    /// The open thread, or `nil` when no panel is shown.
    public var panel: ThreadPanelState?
    /// Followed threads, newest activity first (the Threads list).
    public var items: [ThreadListItem]
    /// Whether the Threads row is chosen. `selected` is then `nil`, as it is
    /// for the Mentions row.
    public var showingList: Bool
    /// The Threads row's badge: followed threads with something unread.
    public var unreadCount: Int
    /// Where those threads are: each of these conversations shows the unread
    /// dot, as a top-level unread does (session 58).
    public var unreadConversations: Set<Conversation.ID>

    public init(
        summaries: [MessageThread.ID: MessageThread] = [:],
        panel: ThreadPanelState? = nil,
        items: [ThreadListItem] = [],
        showingList: Bool = false,
        unreadCount: Int = 0,
        unreadConversations: Set<Conversation.ID> = []
    ) {
        self.summaries = summaries
        self.panel = panel
        self.items = items
        self.showingList = showingList
        self.unreadCount = unreadCount
        self.unreadConversations = unreadConversations
    }
}

/// The thread panel's content.
public struct ThreadPanelState: Sendable, Equatable {
    public var thread: MessageThread
    public var conversationTitle: String
    /// The first message included, oldest first.
    public var messages: [Message]
    /// The reply to scroll to once, after a mention or a notification opened
    /// the panel; `nil` means the newest reply.
    public var scrollTarget: Message.ID?
    /// A Follow or Unfollow is on its way: the toggle waits for it.
    public var followPending: Bool
    /// The files staged in this thread's composer (session 60).
    public var stagedAttachments: [ComposerAttachment]

    public init(
        thread: MessageThread,
        conversationTitle: String,
        messages: [Message] = [],
        scrollTarget: Message.ID? = nil,
        followPending: Bool = false,
        stagedAttachments: [ComposerAttachment] = []
    ) {
        self.thread = thread
        self.conversationTitle = conversationTitle
        self.messages = messages
        self.scrollTarget = scrollTarget
        self.followPending = followPending
        self.stagedAttachments = stagedAttachments
    }

    /// The message that started the thread, when the store has it.
    public var firstMessage: Message? {
        messages.first { !$0.isReply }
    }

    public var replies: [Message] {
        messages.filter(\.isReply)
    }
}

/// One row of the Threads list. Values only, like `MentionItem`: the mapping
/// from a stored thread is this initializer, pure, and tested.
public struct ThreadListItem: Identifiable, Sendable, Equatable {
    /// A thread in its conversation. A topic id is unique only inside its
    /// conversation, so the thread's id alone could name two rows (ruling 8).
    /// Composed from the two ids, never parsed.
    public struct Key: Hashable, Sendable {
        public let conversation: Conversation.ID
        public let thread: MessageThread.ID

        public init(conversation: Conversation.ID, thread: MessageThread.ID) {
            self.conversation = conversation
            self.thread = thread
        }
    }

    public let id: Key
    public let conversationID: Conversation.ID
    public let conversationTitle: String
    public let senderName: String
    public let root: Message
    public let thread: MessageThread

    public init(
        root: Message, thread: MessageThread, conversation: Conversation,
        directory: [Member.ID: Member], me: Member.ID?
    ) {
        id = Key(conversation: conversation.id, thread: thread.id)
        conversationID = conversation.id
        conversationTitle = Display.title(of: conversation, directory: directory, me: me)
        senderName = Display.name(of: root.sender, in: directory)
        self.root = root
        self.thread = thread
    }
}

/// What the window can ask for about threads. **Optional on
/// `ChatSceneActions`, and `nil` is the point**: a backend without threads
/// gets no mark, no menu item, no panel and no Threads row.
@MainActor
public struct ThreadActions {
    public var open: (MessageThread.ID) -> Void
    public var close: () -> Void
    public var sendReply: (ComposedMessage) -> Void
    public var setFollowed: (Bool) -> Void
    public var markUnread: (Message) -> Void
    public var showList: () -> Void
    public var openItem: (Conversation.ID, MessageThread.ID) -> Void
    /// The open thread's files: the +, its chips and drops on the panel.
    /// `nil` draws no + there and takes no drop (session 60).
    public var attachments: ComposerAttachmentActions?

    public init(
        open: @escaping (MessageThread.ID) -> Void,
        close: @escaping () -> Void,
        sendReply: @escaping (ComposedMessage) -> Void,
        setFollowed: @escaping (Bool) -> Void,
        markUnread: @escaping (Message) -> Void,
        showList: @escaping () -> Void,
        openItem: @escaping (Conversation.ID, MessageThread.ID) -> Void,
        attachments: ComposerAttachmentActions? = nil
    ) {
        self.open = open
        self.close = close
        self.sendReply = sendReply
        self.setFollowed = setFollowed
        self.markUnread = markUnread
        self.showList = showList
        self.openItem = openItem
        self.attachments = attachments
    }
}
