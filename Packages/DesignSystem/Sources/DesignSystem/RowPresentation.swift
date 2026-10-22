import ChatKit
import Foundation

/// A row must not carry the window's full snapshot: SwiftUI compares stored
/// view properties while updating each child, even when its body reads only
/// a small part of that snapshot.
struct MessageRowState: Equatable {
    let deliveryStatus: MessageDeliveryStatus?
    let checkingDelivery: Bool
    let isPendingMessage: Bool
    var canUseProviderActions: Bool {
        deliveryStatus == nil && !isPendingMessage
    }

    let me: Member.ID?
    let directory: [Member.ID: Member]
    let thread: MessageThread?
    let downloads: [String: AttachmentDownloadState]
    /// The sender's presence, for a row that draws their picture
    /// (`badgesSender`); `nil` otherwise, so presence changes reach only the
    /// rows that show a dot, not every row in the transcript (session 81).
    let senderPresence: Presence?

    init(
        message: Message, scene: ChatSceneState, showsThread: Bool = true,
        downloads: [String: AttachmentDownloadState]? = nil, badgesSender: Bool = false
    ) {
        deliveryStatus = scene.messageDeliveryStatuses[message.id]
        checkingDelivery = scene.checkingMessageDeliveries.contains(message.id)
        isPendingMessage = scene.pendingMessages.contains(message.id)
        me = scene.me
        senderPresence = badgesSender
            ? Display.presence(
                of: message.sender, directory: scene.directory, me: scene.me, connection: scene.connection
            )
            : nil
        thread = showsThread ? scene.threads.summaries[message.threadID] : nil
        let repliers = Array((thread?.recentRepliers ?? []).prefix(3))
        let originalSender = message.forwardedSnapshot.map { [$0.source.sender] } ?? []
        directory = RowDirectory.avatars([message.sender] + repliers + originalSender, in: scene.directory)
        let availableDownloads = downloads ?? scene.downloads
        let attachments = message.attachments + (message.forwardedSnapshot?.attachments ?? [])
        self.downloads = attachments.reduce(into: [:]) { result, attachment in
            result[attachment.id] = availableDownloads[attachment.id]
        }
    }
}

struct ConversationRowState: Equatable {
    let me: Member.ID?
    let directory: [Member.ID: Member]
    let connection: ConnectionState
    let unreadHidden: Bool
    let showsUnread: Bool
    let dimmed: Bool
    let muted: Bool

    init(conversation: Conversation, scene: ChatSceneState) {
        me = scene.me
        connection = scene.connection
        directory = conversation.members.reduce(into: [:]) { result, id in
            result[id] = scene.directory[id]
        }
        unreadHidden = scene.unreadHidden.contains(conversation.id)
        showsUnread = ThreadsPresentation.showsUnread(conversation, hidden: unreadHidden)
        dimmed = scene.dimmed.contains(conversation.id)
        muted = scene.muted.contains(conversation.id)
    }
}

enum RowDirectory {
    /// Avatars draw only a name and photo from here. Presence, status and
    /// calendar changes must not invalidate transcript rows; a row that shows
    /// its sender's dot carries that one value itself (`senderPresence`).
    static func avatars(_ ids: [Member.ID], in directory: [Member.ID: Member]) -> [Member.ID: Member] {
        ids.reduce(into: [:]) { result, id in
            guard let member = directory[id] else { return }
            result[id] = Member(
                id: id, kind: member.kind, displayName: member.displayName, avatarURL: member.avatarURL
            )
        }
    }
}
