import ChatKit
import DesignSystem
import Foundation
import Observation

/// This session's file downloads: one transfer per attachment at most, a
/// staging file per transfer, and a finished file placed in the download
/// folder under a name that overwrites nothing. `done` is remembered for this
/// launch only.
@MainActor @Observable
public final class DownloadCoordinator {
    public typealias Download = @Sendable (
        Attachment, URL, @escaping @Sendable (AttachmentProgress) -> Void
    ) async throws -> Void

    public private(set) var states: [String: AttachmentDownloadState] = [:]
    public private(set) var folder: DownloadFolder

    private var placed: [String: URL] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    /// Which transfer is the current one for each attachment. A transfer that
    /// `stopAll` cancelled can still be unwinding when the same attachment is
    /// started again, and only the current one may write state.
    private var tokens: [String: UUID] = [:]
    private let staging: URL
    private let platform: any DownloadPlatform
    private let download: Download

    public init(staging: URL, platform: any DownloadPlatform, download: @escaping Download) {
        self.staging = staging
        self.platform = platform
        self.download = download
        folder = platform.folder
    }

    public func start(_ attachment: Attachment) {
        begin(attachment, into: nil)
    }

    public func cancel(_ attachment: Attachment) {
        tasks[attachment.id]?.cancel()
    }

    /// Opens the finished file; downloads it again when it has since been
    /// moved or deleted, rather than opening nothing. Does nothing while a
    /// transfer is running, the same rule as `begin`.
    public func open(_ attachment: Attachment) {
        guard tasks[attachment.id] == nil else { return }
        guard let file = placed[attachment.id], Self.exists(file) else {
            placed[attachment.id] = nil
            states[attachment.id] = nil
            begin(attachment, into: nil)
            return
        }
        platform.open(file)
    }

    public func reveal(_ attachment: Attachment) {
        if let file = placed[attachment.id], Self.exists(file) {
            platform.reveal(file)
        }
    }

    /// Copies a finished file to a place the person picks, or downloads
    /// straight there when it is not downloaded yet.
    public func saveAs(_ attachment: Attachment) {
        guard tasks[attachment.id] == nil,
              let target = platform.chooseSaveDestination(suggestedName: DownloadNaming.leaf(attachment.name))
        else { return }
        if let file = placed[attachment.id], Self.exists(file) {
            do {
                // The save panel already asked whether to replace an existing file.
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.copyItem(at: file, to: target)
            } catch {
                states[attachment.id] = .failed(Self.message(for: error))
            }
            return
        }
        begin(attachment, into: target)
    }

    public func chooseFolder() {
        platform.chooseFolder()
        folder = platform.folder
    }

    public func useDefaultFolder() {
        platform.useDefaultFolder()
        folder = platform.folder
    }

    /// Sign-out: every transfer cancelled, the staging directory gone. Files
    /// already placed are the person's and stay.
    public func stopAll() {
        for (id, task) in tasks {
            task.cancel()
            // The transfer is no longer current, so it will not clear this itself.
            states[id] = nil
        }
        tasks = [:]
        tokens = [:]
        try? FileManager.default.removeItem(at: staging)
    }

    /// Test seam: the running transfer, if any.
    func task(for attachment: Attachment) -> Task<Void, Never>? {
        tasks[attachment.id]
    }

    // MARK: - One transfer

    private func begin(_ attachment: Attachment, into target: URL?) {
        guard tasks[attachment.id] == nil else { return }
        let token = UUID()
        tokens[attachment.id] = token
        states[attachment.id] = .downloading(AttachmentProgress(
            bytesReceived: 0,
            totalBytes: attachment.byteSize
        ))
        tasks[attachment.id] = Task { [weak self] in
            await self?.run(attachment, into: target, token: token)
        }
    }

    private func run(_ attachment: Attachment, into target: URL?, token: UUID) async {
        let id = attachment.id
        let directory = staging.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let staged = directory.appendingPathComponent(DownloadNaming.leaf(attachment.name))
        defer {
            try? FileManager.default.removeItem(at: directory)
            if isCurrent(token, for: id) {
                tasks[id] = nil
                tokens[id] = nil
            }
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try await download(attachment, staged) { progress in
                Task { @MainActor [weak self] in self?.progressed(id, progress, token: token) }
            }
            try Task.checkCancellation()
            let file = try place(staged, attachment: attachment, into: target)
            if isCurrent(token, for: id) {
                placed[id] = file
                states[id] = .done
            }
        } catch {
            if isCurrent(token, for: id) {
                states[id] = Task.isCancelled ? nil : .failed(Self.message(for: error))
            }
        }
    }

    private func isCurrent(_ token: UUID, for id: String) -> Bool {
        tokens[id] == token
    }

    /// Late progress - it hops to this actor - never moves a finished or
    /// failed chip back to downloading, nor a newer transfer's chip.
    private func progressed(_ id: String, _ progress: AttachmentProgress, token: UUID) {
        guard isCurrent(token, for: id), case .downloading = states[id] else { return }
        states[id] = .downloading(progress)
    }

    private func place(_ staged: URL, attachment: Attachment, into target: URL?) throws -> URL {
        if let target {
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: staged, to: target)
            return target
        }
        let result = try platform.withAccess { folder in
            try DownloadNaming.place(staged, as: DownloadNaming.leaf(attachment.name), in: folder)
        }
        folder = platform.folder
        return result
    }

    private static func exists(_ file: URL) -> Bool {
        FileManager.default.fileExists(atPath: file.path(percentEncoded: false))
    }

    private static let couldNotSave = "The download could not be saved"

    /// What the chip says. Never a URL and never a token: a `ChatError`'s
    /// payload should already be safe to show (`LocalBridgeBackend.chatError`),
    /// and a payload that still holds a URL is replaced rather than trusted.
    static func message(for error: any Error) -> String {
        if let unavailable = error as? DownloadFolderUnavailable {
            return "Kibble can't save to “\(unavailable.folderName)”"
        }
        switch error as? ChatError {
        case .signInRequired, .sessionExpired, .notAuthenticated:
            return "Sign in again to download files"
        case .unsupported:
            return "This account can't download files"
        case let .server(status, _):
            return "The download was refused (HTTP \(status))"
        case let .transport(message), let .unknown(message), let .decoding(message):
            return message.contains("://") ? couldNotSave : message
        case .rateLimited:
            return "Too many requests - try again shortly"
        case nil:
            return couldNotSave
        }
    }
}
