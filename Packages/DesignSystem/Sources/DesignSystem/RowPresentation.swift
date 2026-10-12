import ChatKit
import Foundation

/// A row must not carry the window's full snapshot: SwiftUI compares stored
/// view properties while updating each child, even when its body reads only
/// a small part of that snapshot.
struct MessageRowState: Equatable {
    let me: Member.ID?
    let directory: [Member.ID: Member]
    let thread: MessageThread?
    let downloads: [String: AttachmentDownloadState]

    init(
        message: Message, scene: ChatSceneState, showsThread: Bool = true,
        downloads: [String: AttachmentDownloadState]? = nil
    ) {
        me = scene.me
        thread = showsThread ? scene.threads.summaries[message.threadID] : nil
        let repliers = Array((thread?.recentRepliers ?? []).prefix(3))
        directory = RowDirectory.avatars([message.sender] + repliers, in: scene.directory)
        let availableDownloads = downloads ?? scene.downloads
        self.downloads = message.attachments.reduce(into: [:]) { result, attachment in
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
    /// Unbadged avatars draw only a name and photo. Presence, status and
    /// calendar changes must not invalidate transcript rows.
    static func avatars(_ ids: [Member.ID], in directory: [Member.ID: Member]) -> [Member.ID: Member] {
        ids.reduce(into: [:]) { result, id in
            guard let member = directory[id] else { return }
            result[id] = Member(
                id: id, kind: member.kind, displayName: member.displayName, avatarURL: member.avatarURL
            )
        }
    }
}
