import ChatKit
import DesignSystem
import Foundation
import SyncEngine

/// Files staged in the composer: the + and the drop targets, the chips
/// they become, and the cache that keeps a sent picture's bytes.
extension AppEnvironment {
    /// A picture larger than this is fetched back from Google rather than
    /// kept from the upload: the cache holds it in memory too.
    static let seedLimit = 20 * 1_048_576

    /// The conversation composer's.
    var composerAttachmentActions: ComposerAttachmentActions? {
        composerAttachmentActions(in: .conversation)
    }

    /// Offered only while a session runs on a backend that can both send and
    /// upload; `nil` draws no + and no drop target. `target` is the composer
    /// they stage into: the conversation's, or the open thread's.
    func composerAttachmentActions(in target: StagingTarget) -> ComposerAttachmentActions? {
        guard let capabilities = runningModel?.capabilities,
              capabilities.canSendMessages, capabilities.canSendAttachments
        else { return nil }
        return ComposerAttachmentActions(
            choose: { [weak self] in
                guard let self else { return }
                stageFiles(services.chooseFilesToSend(), in: target)
            },
            stage: { [weak self] in self?.stageFiles($0, in: target) },
            remove: { [weak self] in self?.runningModel?.unstage($0, in: target) }
        )
    }

    /// Inspects each file and stages what can be sent; a folder or a file
    /// that cannot be read is named in a banner instead.
    func stageFiles(_ urls: [URL], in target: StagingTarget) {
        guard let model = runningModel, !urls.isEmpty else { return }
        var files: [OutgoingAttachment] = []
        var unreadable: [String] = []
        for url in urls {
            if let file = OutgoingFiles.attachment(for: url) {
                files.append(file)
            } else {
                unreadable.append(url.lastPathComponent)
            }
        }
        model.stage(files, unreadable: unreadable, in: target)
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
    /// person chose rather than fetching it back. Read off the main actor,
    /// and the cache read through `self` afterwards, for
    /// `loadAttachment(_:size:)`'s reason: a sign-out meanwhile has erased it.
    func seedUpload(_ attachment: Attachment, from file: OutgoingAttachment) {
        guard file.isImage, file.byteSize <= Self.seedLimit else { return }
        let url = file.file
        Task { [weak self] in
            let data = await Task.detached(priority: .utility) { try? Data(contentsOf: url) }.value
            guard let data, let cache = self?.attachments else { return }
            await cache.seed(data, for: attachment)
        }
    }
}
