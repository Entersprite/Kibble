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

/// What `ChatSessionModel` keeps for staged files: per conversation, so a
/// file never follows the person into another conversation, the reason
/// `failed` keeps its conversation too.
@MainActor
public struct ComposerFiles {
    public internal(set) var staged: [Conversation.ID: [StagedAttachment]] = [:]
    /// Tracked so `stop()` cancels them: an upload left running would post
    /// into an account that has signed out.
    var sends: [UUID: Task<Void, Never>] = [:]
    /// `ChatSessionModel.didUpload`'s storage.
    var didUpload: (@MainActor (Attachment, OutgoingAttachment) -> Void)?

    nonisolated init() {}

    mutating func cancelSends() {
        for task in sends.values {
            task.cancel()
        }
        sends = [:]
    }
}

public extension ChatSessionModel {
    /// Told about each upload once it has an attachment, with the file it came
    /// from, so the host can keep bytes it already holds (`AttachmentCache`)
    /// instead of fetching back what it just sent. Set by the host.
    var didUpload: (@MainActor (Attachment, OutgoingAttachment) -> Void)? {
        get { composerFiles.didUpload }
        set { composerFiles.didUpload = newValue }
    }

    /// The open conversation's staged files.
    var stagedAttachments: [StagedAttachment] {
        selected.flatMap { composerFiles.staged[$0] } ?? []
    }

    /// Stages files in the open conversation. A file already staged there is
    /// not staged twice, and a file over `OutgoingAttachment.maximumByteSize`
    /// is refused with a banner rather than uploaded for minutes and refused
    /// by Google `[Verify]`. `unreadable` names what the host could not read
    /// (a folder, a file it has no access to), for the same banner.
    func stage(_ files: [OutgoingAttachment], unreadable: [String] = []) {
        guard let selected, capabilities.canSendAttachments else { return }
        if !unreadable.isEmpty {
            let names = unreadable.joined(separator: ", ")
            Task { [engine] in
                await engine
                    .record(ChatError.unknown("Kibble can't send \(names): only files can be attached"))
            }
        }
        var list = composerFiles.staged[selected] ?? []
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
        composerFiles.staged[selected] = list
    }

    /// Removes a staged file from the open conversation, unless it is
    /// uploading: a send in flight owns it until it ends.
    func unstage(_ id: String) {
        guard let selected, var list = composerFiles.staged[selected] else { return }
        list.removeAll { $0.id == id && !$0.isUploading }
        composerFiles.staged[selected] = list.isEmpty ? nil : list
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
    internal func sendStaged(_ text: String, in conversation: Conversation.ID) {
        let batch = (composerFiles.staged[conversation] ?? []).filter { !$0.isUploading }
        guard !batch.isEmpty else { return }
        for item in batch {
            setState(.uploading(nil), of: item.id, in: conversation)
        }
        let key = UUID()
        composerFiles.sends[key] = Task { @MainActor [weak self] in
            await self?.upload(batch.map(\.attachment), caption: text, in: conversation)
            self?.composerFiles.sends[key] = nil
        }
    }

    private func upload(
        _ files: [OutgoingAttachment],
        caption text: String,
        in conversation: Conversation.ID
    ) async {
        var caption = text
        for (index, file) in files.enumerated() {
            let uploaded: Attachment
            do {
                uploaded = try await engine.uploadAttachment(file, to: conversation) { [weak self] progress in
                    Task { @MainActor in
                        self?.setState(
                            .uploading(progress),
                            of: file.id,
                            in: conversation,
                            onlyIfUploading: true
                        )
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                stopSending(files[index...], failed: file.id, caption: caption, in: conversation)
                return
            }
            guard !Task.isCancelled else { return }
            composerFiles.didUpload?(uploaded, file)
            let posted = await post(uploaded, caption: caption, in: conversation)
            guard !Task.isCancelled else { return }
            guard posted else {
                stopSending(files[index...], failed: file.id, caption: caption, in: conversation)
                return
            }
            remove(file.id, from: conversation)
            caption = ""
        }
    }

    /// One message carrying one upload, shown at once, the same way `send(_:)`
    /// shows a text: a `local/` row, retracted by id if the send is refused.
    private func post(
        _ attachment: Attachment,
        caption: String,
        in conversation: Conversation.ID
    ) async -> Bool {
        let localID = UUID().uuidString
        let optimisticID = Message.ID("local/\(localID)")
        var undo: [StoreWrite] = []
        if let me {
            try? store.apply([.upsertMessage(Message(
                id: optimisticID,
                conversationID: conversation,
                threadID: MessageThread.ID(""),
                sender: me,
                text: caption,
                createdAt: Date(),
                attachments: [attachment],
                localID: localID
            ))])
            undo = [.removeMessage(id: optimisticID)]
        }
        return await engine.submit(
            .sendMessage(
                conversationID: conversation, threadID: nil, text: caption, localID: localID,
                attachments: [attachment]
            ),
            undoing: undo
        )
    }

    private func stopSending(
        _ remaining: ArraySlice<OutgoingAttachment>,
        failed id: String,
        caption: String,
        in conversation: Conversation.ID
    ) {
        for file in remaining {
            setState(file.id == id ? .failed : .ready, of: file.id, in: conversation)
        }
        if !caption.isEmpty {
            failed = (conversationID: conversation, text: caption)
        }
    }

    private func setState(
        _ state: StagedAttachment.State,
        of id: String,
        in conversation: Conversation.ID,
        onlyIfUploading: Bool = false
    ) {
        guard var list = composerFiles.staged[conversation],
              let index = list.firstIndex(where: { $0.id == id }),
              !onlyIfUploading || list[index].isUploading
        else { return }
        list[index].state = state
        composerFiles.staged[conversation] = list
    }

    private func remove(_ id: String, from conversation: Conversation.ID) {
        guard var list = composerFiles.staged[conversation] else { return }
        list.removeAll { $0.id == id }
        composerFiles.staged[conversation] = list.isEmpty ? nil : list
    }
}
