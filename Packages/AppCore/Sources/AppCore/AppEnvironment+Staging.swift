import ChatKit
import DesignSystem
import Foundation
import Observation
import SyncEngine

/// Files staged in the composer: the +, the drop targets and paste, the
/// chips they become, how long each stays readable, and the cache that keeps
/// a sent picture's bytes.
extension AppEnvironment {
    /// A picture larger than this is fetched back from Google rather than
    /// kept from the upload: the cache holds it in memory too.
    static let seedLimit = 20 * 1_048_576

    /// The conversation composer's.
    var composerAttachmentActions: ComposerAttachmentActions? {
        composerAttachmentActions(in: .conversation)
    }

    /// Offered only while a session runs on a backend that can both send and
    /// upload; `nil` draws no +, no drop target and no pasting of files.
    /// `target` is the composer they stage into: the conversation's, or the
    /// open thread's.
    func composerAttachmentActions(in target: StagingTarget) -> ComposerAttachmentActions? {
        guard let capabilities = runningModel?.capabilities,
              capabilities.canSendMessages, capabilities.canSendAttachments
        else { return nil }
        return ComposerAttachmentActions(
            stage: { [weak self] in self?.stageFiles($0, in: target) },
            remove: { [weak self] in self?.unstage($0, in: target) },
            stageImage: { [weak self] in self?.stagePastedImage($0, in: target) }
        )
    }

    /// Inspects each file and stages what can be sent; a folder or a file
    /// that cannot be read is named in a banner instead. Each file is
    /// readable from here until it leaves every composer
    /// (`StagedFileCustody`): access starts before the inspection, which
    /// reads it too, and anything not staged is let go at once.
    func stageFiles(_ urls: [URL], in target: StagingTarget) {
        guard let model = runningModel, !urls.isEmpty else { return }
        var files: [OutgoingAttachment] = []
        var unreadable: [String] = []
        for url in urls {
            stagedFiles?.access(url, id: OutgoingFiles.id(for: url))
            if let file = OutgoingFiles.attachment(for: url) {
                files.append(file)
            } else {
                unreadable.append(url.lastPathComponent)
            }
        }
        model.stage(files, unreadable: unreadable, in: target)
        stagedFiles?.release(keeping: model.stagedFileIDs)
    }

    func unstage(_ id: String, in target: StagingTarget) {
        guard let model = runningModel else { return }
        model.unstage(id, in: target)
        stagedFiles?.release(keeping: model.stagedFileIDs)
    }

    /// A picture pasted as data, written into a folder of its own in this
    /// app's temporary directory and staged like any file; the folder is
    /// deleted once the picture is sent or removed (`StagedFileCustody`).
    /// A folder per paste, so two pastes are two files, never one staged
    /// twice.
    func stagePastedImage(_ image: ComposerPastedImage, in target: StagingTarget) {
        guard runningModel != nil, let custody = stagedFiles else { return }
        let pasted = FileManager.default.temporaryDirectory
            .appending(path: "Pasted Images", directoryHint: .isDirectory)
        StagedFileCustody.sweepLeftovers(in: pasted)
        let folder = pasted.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let file = folder.appending(path: OutgoingFiles.pastedImageName(at: Date(), type: image.type))
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try image.data.write(to: file)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            return
        }
        custody.own(folder, id: OutgoingFiles.id(for: file))
        stageFiles([file], in: target)
    }

    /// Follows `model`'s staged files for this session, ending custody of
    /// each as it leaves: sent and removed by the model on its own, after an
    /// upload, as well as through `unstage`.
    func followStagedFiles(of model: ChatSessionModel) {
        endStagedFiles()
        let custody = StagedFileCustody()
        stagedFiles = custody
        stagedFilesTask = Task { [weak custody] in
            for await ids in Observations({ model.stagedFileIDs }) {
                guard !Task.isCancelled else { return }
                custody?.release(keeping: ids)
            }
        }
    }

    /// The session is ending: every staged file is let go, and pasted
    /// pictures deleted.
    func endStagedFiles() {
        stagedFilesTask?.cancel()
        stagedFilesTask = nil
        stagedFiles?.releaseAll()
        stagedFiles = nil
    }

    static func composerAttachments(_ staged: [StagedAttachment]) -> [ComposerAttachment] {
        staged.map { item in
            ComposerAttachment(
                id: item.id,
                name: item.attachment.name,
                byteSize: item.attachment.byteSize,
                isImage: item.attachment.isImage,
                file: item.attachment.file,
                state: state(of: item)
            )
        }
    }

    private static func state(of item: StagedAttachment) -> ComposerAttachment.State {
        switch item.state {
        case .ready:
            .ready
        case let .uploading(progress):
            .uploading(fraction: progress.flatMap { progress in
                progress.totalBytes.flatMap { $0 > 0 ? Double(progress.bytesReceived) / Double($0) : nil }
            })
        case .failed:
            .failed
        }
    }

    /// Keeps a sent picture's bytes, so its bubble draws from the file the
    /// person chose rather than fetching it back. The cache is captured
    /// before the file read: a later sign-in must not receive bytes from the
    /// session that started this upload. `erase()` rejects a late seed on the
    /// old cache.
    ///
    /// The file stays readable until the read is done, even if the message
    /// is posted and the file unstaged first.
    func seedUpload(_ attachment: Attachment, from file: OutgoingAttachment) {
        let task = seedUpload(attachment, from: file) { url in
            await Task.detached(priority: .utility) { try? Data(contentsOf: url) }.value
        }
        guard let task, let custody = stagedFiles else { return }
        custody.beginRead(file.id)
        Task { [weak custody] in
            await task.value
            custody?.endRead(file.id)
        }
    }

    /// The reader is supplied by the production file read above and can be
    /// held in a test across sign-out to prove where its result is stored.
    @discardableResult
    func seedUpload(
        _ attachment: Attachment,
        from file: OutgoingAttachment,
        read: @escaping @Sendable (URL) async -> Data?
    ) -> Task<Void, Never>? {
        guard file.isImage, file.byteSize <= Self.seedLimit, let cache = attachments else { return nil }
        let url = file.file
        return Task {
            let data = await read(url)
            guard let data else { return }
            await cache.seed(data, for: attachment)
        }
    }
}
