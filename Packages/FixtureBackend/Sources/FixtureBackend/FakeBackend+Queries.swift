import ChatKit
import Foundation

// MARK: - Reads

public extension FakeBackend {
    /// The whole conversation list.
    ///
    /// Reads deliberately do **not** require a connection. The fixture world is
    /// local, so refusing to answer would be theatre - and it would stop
    /// someone building a sidebar from seeing anything until they had wired up
    /// a lifecycle. Writes are the ones that need a live session.
    func loadConversations() async throws -> [Conversation] {
        world.conversations
    }

    /// A page of history, oldest to newest: the newest `pageSize` top-level
    /// messages ending just before `before`, each with every reply in its
    /// thread. A page of topics, the way real history pages (threads spec
    /// §2.2), so a thread never arrives without its first message; in a world
    /// without replies it is exactly a page of messages.
    ///
    /// `before: nil` is the most recent page. A cursor the conversation does
    /// not contain **throws** rather than returning an empty page: an empty
    /// page is indistinguishable from "no more history", so a client that had
    /// muddled two conversations' identifiers would silently render a blank
    /// scrollback instead of failing.
    ///
    /// Each thread in the page with a reply is reported as `.threadChanged`
    /// while it loads, as the bridge reports history's topics.
    ///
    /// The seam records `before:` as provisional - the wire protocol pages by
    /// revision anchors, not message identifiers - so this is one plausible
    /// reading of that signature, not evidence about the real one.
    func loadMessages(
        in conversation: Conversation.ID,
        before: Message.ID?
    ) async throws -> [Message] {
        guard world.conversation(conversation) != nil else {
            throw ChatError.unknown("no conversation \(conversation) in this fixture world")
        }
        let all = world.messages(in: conversation)
        var earlier = all[...]
        if let before {
            guard let index = all.firstIndex(where: { $0.id == before }) else {
                throw ChatError.unknown("message \(before) is not in \(conversation)")
            }
            earlier = all[..<index]
        }
        let roots = earlier.filter { !$0.isReply }.suffix(pageSize)
        let rootIDs = Set(roots.map(\.id))
        let threads = Set(roots.map(\.threadID))
        let page = all.filter { $0.isReply ? threads.contains($0.threadID) : rootIDs.contains($0.id) }
        emitThreadState(of: page, in: conversation)
        return page
    }
}

// MARK: - The one awaited write

public extension FakeBackend {
    /// Changes a conversation's notification level.
    ///
    /// Separate from `send(_:)` because a settings toggle must not spring back
    /// while a round trip is in flight, so this one has a completion worth
    /// awaiting. The `ChatCommand` case still exists for a bridge server
    /// forwarding it on, and both paths land in the same place.
    func setNotificationSetting(
        _ level: NotificationLevel,
        for conversation: Conversation.ID
    ) async throws {
        try require(capabilities.canSetNotificationLevel, "canSetNotificationLevel")
        try requireConnected()
        try updateConversation(conversation) { $0.notificationLevel = level }
    }
}

// MARK: - Attachments

public extension FakeBackend {
    /// `FixtureImage.png` for any attachment some message in the world
    /// carries, or this fake has uploaded, at either size. No connection needed, like the other reads.
    /// An attachment the world does not hold is refused rather than invented,
    /// the same rule `FakeHTTPTransport` follows for a script that ran out.
    func attachmentData(_ attachment: Attachment, size _: AttachmentSize) async throws -> Data {
        try require(capabilities.canFetchAttachments, "canFetchAttachments")
        let held = uploaded[attachment.id] != nil
            || world.messages.contains(where: { $0.attachments.contains { $0.id == attachment.id } })
        guard held else {
            throw ChatError.unknown("the fixture world holds no attachment \(attachment.id)")
        }
        return FixtureImage.png
    }

    /// The fixture's one picture, for `acme.example` URLs only, so a demo card
    /// never reaches the network and a stray URL fails loudly (links spec §7.6).
    func remoteImage(_ url: URL) async throws -> Data {
        try require(capabilities.canFetchRemoteImages, "canFetchRemoteImages")
        guard let host = url.host()?.lowercased(), host == "acme.example" || host.hasSuffix(".acme.example")
        else { throw ChatError.unknown("the fixture serves no image from this host") }
        return FixtureImage.png
    }
}

// MARK: - Mutation helpers

extension FakeBackend {
    /// Applies a change to one stored conversation and announces the new
    /// snapshot. Used wherever no more specific event exists for what changed.
    @discardableResult
    func updateConversation(
        _ id: Conversation.ID,
        emitUpdate: Bool = true,
        _ change: (inout Conversation) -> Void
    ) throws -> Conversation {
        guard let index = world.conversations.firstIndex(where: { $0.id == id }) else {
            throw ChatError.unknown("no conversation \(id) in this fixture world")
        }
        change(&world.conversations[index])
        let updated = world.conversations[index]
        if emitUpdate {
            emit(.conversationUpdated(updated))
        }
        return updated
    }

    /// Applies a change to one stored message and hands it back. The caller
    /// decides which event that warrants, because the answer differs: an edit
    /// is `messageUpdated`, a deletion is `messageDeleted`, a reaction is
    /// `reactionChanged`.
    @discardableResult
    func updateMessage(_ id: Message.ID, _ change: (inout Message) -> Void) throws -> Message {
        guard let index = world.messages.firstIndex(where: { $0.id == id }) else {
            throw ChatError.unknown("no message \(id) in this fixture world")
        }
        change(&world.messages[index])
        return world.messages[index]
    }
}
