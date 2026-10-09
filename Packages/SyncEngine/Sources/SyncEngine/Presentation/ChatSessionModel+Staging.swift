import ChatKit
import Foundation

// MARK: - Files staged in the composer, and the sends that upload them

/// One staged file and how far its upload has got.
public struct StagedAttachment: Hashable, Sendable, Identifiable {
    public enum State: Hashable, Sendable {
        /// Waiting for Send.
        case ready
        /// Part of a send in flight. Cannot be removed until it ends.
        case uploading(AttachmentProgress?)
        /// Its upload or its message was refused. Send tries it again.
        case failed
    }

    public var attachment: OutgoingAttachment
    public var state: State

    public var id: String {
        attachment.id
    }

    public init(attachment: OutgoingAttachment, state: State = .ready) {
        self.attachment = attachment
        self.state = state
    }

    var isUploading: Bool {
        if case .uploading = state {
            true
        } else {
            false
        }
    }
}

/// A composer that stages files: a conversation's, or one of its threads'
/// (session 60).
struct StagingKey: Hashable {
    let conversation: Conversation.ID
    /// `nil` for the conversation's own composer.
    let thread: MessageThread.ID?
}

/// What `ChatSessionModel` keeps for staged files: per composer, so a file
/// never follows the person into another conversation or thread, the reason
/// `failed` keeps its conversation too.
@MainActor
public struct ComposerFiles {
    var staged: [StagingKey: [StagedAttachment]] = [:]
    /// Tracked so `stop()` cancels them: an upload left running would post
    /// into an account that has signed out.
    var sends: [UUID: Task<Void, Never>] = [:]
    /// `ChatSessionModel.didUpload`'s storage.
    var didUpload: (@MainActor (Attachment, OutgoingAttachment) -> Void)?

    nonisolated init() {}

    /// Cancels every send and forgets every staged file: what `stop()` asks
    /// for, so a cancelled file is not left uploading forever in a model
    /// that is reused.
    mutating func reset() {
        for task in sends.values {
            task.cancel()
        }
        sends = [:]
        staged = [:]
    }
}

/// Where files are staged: the conversation's composer, or the open thread's.
public enum StagingTarget: Sendable {
    case conversation
    case openThread
}

public extension ChatSessionModel {
    /// The open thread's staged files.
    var threadStagedAttachments: [StagedAttachment] {
        key(for: .openThread).flatMap { composerFiles.staged[$0] } ?? []
    }

    /// Told about each upload once it has an attachment, with the file it came
    /// from, so the host can keep bytes it already holds (`AttachmentCache`)
    /// instead of fetching back what it just sent. Set by the host.
    var didUpload: (@MainActor (Attachment, OutgoingAttachment) -> Void)? {
        get { composerFiles.didUpload }
        set { composerFiles.didUpload = newValue }
    }

    /// The open conversation's staged files.
    var stagedAttachments: [StagedAttachment] {
        key(for: .conversation).flatMap { composerFiles.staged[$0] } ?? []
    }

    /// Stages files in the open conversation, or its open thread. A file already staged there is
    /// not staged twice, and a file over `OutgoingAttachment.maximumByteSize`
    /// is refused with a banner rather than uploaded for minutes and refused
    /// by Google `[Verify]`. `unreadable` names what the host could not read
    /// (a folder, a file it has no access to), for the same banner.
    func stage(
        _ files: [OutgoingAttachment],
        unreadable: [String] = [],
        in target: StagingTarget = .conversation
    ) {
        guard let key = key(for: target), capabilities.canSendAttachments else { return }
        if !unreadable.isEmpty {
            let names = unreadable.joined(separator: ", ")
            Task { [engine] in
                await engine
                    .record(ChatError.unknown("Kibble can't send \(names): only files can be attached"))
            }
        }
        var list = composerFiles.staged[key] ?? []
        for file in files where !list.contains(where: { $0.id == file.id }) {
            guard file.byteSize <= OutgoingAttachment.maximumByteSize else {
                Task { [engine] in
                    await engine
                        .record(ChatError.unknown("\(file.name) is larger than 200 MB, Google Chat's limit"))
                }
                continue
            }
            list.append(StagedAttachment(attachment: file))
        }
        composerFiles.staged[key] = list
    }

    /// Removes a staged file from the open conversation or its open thread,
    /// unless it is uploading: a send in flight owns it until it ends.
    func unstage(_ id: String, in target: StagingTarget = .conversation) {
        guard let key = key(for: target), var list = composerFiles.staged[key] else { return }
        list.removeAll { $0.id == id && !$0.isUploading }
        composerFiles.staged[key] = list.isEmpty ? nil : list
    }

    /// The composer `target` names now: none without a selected
    /// conversation, or for a thread, without an open one.
    internal func key(for target: StagingTarget) -> StagingKey? {
        guard let selected else { return nil }
        switch target {
        case .conversation:
            return StagingKey(conversation: selected, thread: nil)
        case .openThread:
            return threads.openThread.map { StagingKey(conversation: selected, thread: $0) }
        }
    }

    /// Uploads each staged file that is not already uploading, and sends each
    /// as its own message once it has uploaded, `text` with the first.
    ///
    /// **One message per file**, because both references send one upload per
    /// message and whether Google accepts several annotations on one is
    /// unknown `[Verify]`. In turn rather than all at once, so the first file
    /// is posted while later ones upload, and a failure part-way loses
    /// nothing already posted.
    ///
    /// **A failure stops the send.** The file that failed is marked failed,
    /// the rest go back to ready, and if `text` has not been posted it comes
    /// back to the composer the way a refused text send's does
    /// (`failedDraft`). Send again tries them again. The banner is the
    /// engine's, recorded where it failed (`uploadAttachment`, `submit`).
    internal func sendStaged(_ caption: ComposedMessage, in key: StagingKey) {
        let batch = (composerFiles.staged[key] ?? []).filter { !$0.isUploading }
        guard !batch.isEmpty else { return }
        for item in batch {
            setState(.uploading(nil), of: item.id, in: key)
        }
        let sendID = UUID()
        composerFiles.sends[sendID] = Task { @MainActor [weak self] in
            await self?.upload(batch.map(\.attachment), caption: caption, in: key)
            self?.composerFiles.sends[sendID] = nil
        }
    }

    private func upload(
        _ files: [OutgoingAttachment],
        caption first: ComposedMessage,
        in key: StagingKey
    ) async {
        var caption = first
        for (index, file) in files.enumerated() {
            let uploaded: Attachment
            do {
                uploaded = try await engine
                    .uploadAttachment(file, to: key.conversation) { [weak self] progress in
                        Task { @MainActor in
                            self?.setState(
                                .uploading(progress),
                                of: file.id,
                                in: key,
                                onlyIfUploading: true
                            )
                        }
                    }
            } catch {
                guard !Task.isCancelled else { return }
                stopSending(files[index...], failed: file.id, caption: caption, in: key)
                return
            }
            guard !Task.isCancelled else { return }
            composerFiles.didUpload?(uploaded, file)
            let posted = await post(uploaded, caption: caption, in: key)
            guard !Task.isCancelled else { return }
            guard posted else {
                stopSending(files[index...], failed: file.id, caption: caption, in: key)
                return
            }
            remove(file.id, from: key)
            caption = ComposedMessage(text: "")
        }
    }

    /// One message carrying one upload, shown at once, the same way `send(_:)`
    /// shows a text: a `local/` row, retracted by id if the send is refused.
    private func post(
        _ attachment: Attachment,
        caption: ComposedMessage,
        in key: StagingKey
    ) async -> Bool {
        let localID = UUID().uuidString
        let optimisticID = Message.ID("local/\(localID)")
        var undo: [StoreWrite] = []
        if let me {
            // A reply's row is marked as one, so it lands in the panel and
            // never in the transcript (`sendReply`'s rule).
            try? store.apply([.upsertMessage(Message(
                id: optimisticID,
                conversationID: key.conversation,
                threadID: key.thread ?? MessageThread.ID(""),
                sender: me,
                text: caption.text,
                createdAt: Date(),
                attachments: [attachment],
                localID: localID,
                mentions: caption.mentions,
                isReply: key.thread != nil
            ))])
            undo = [.removeMessage(id: optimisticID)]
        }
        return await engine.submit(
            .sendMessage(
                conversationID: key.conversation, threadID: key.thread, text: caption.text, localID: localID,
                attachments: [attachment], mentions: caption.mentions
            ),
            undoing: undo
        )
    }

    private func stopSending(
        _ remaining: ArraySlice<OutgoingAttachment>,
        failed id: String,
        caption: ComposedMessage,
        in key: StagingKey
    ) {
        for file in remaining {
            setState(file.id == id ? .failed : .ready, of: file.id, in: key)
        }
        // Not a reply's text: the restore slot is the conversation
        // composer's, and a reply restored there would post at the top level
        // (`sendReply`'s rule).
        if !caption.text.isEmpty, key.thread == nil {
            failed = (conversationID: key.conversation, draft: caption)
        }
    }

    private func setState(
        _ state: StagedAttachment.State,
        of id: String,
        in key: StagingKey,
        onlyIfUploading: Bool = false
    ) {
        guard var list = composerFiles.staged[key],
              let index = list.firstIndex(where: { $0.id == id }),
              !onlyIfUploading || list[index].isUploading
        else { return }
        list[index].state = state
        composerFiles.staged[key] = list
    }

    private func remove(_ id: String, from key: StagingKey) {
        guard var list = composerFiles.staged[key] else { return }
        list.removeAll { $0.id == id }
        composerFiles.staged[key] = list.isEmpty ? nil : list
    }
}
