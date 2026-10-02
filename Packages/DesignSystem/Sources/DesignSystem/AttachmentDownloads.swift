import ChatKit

/// How far a file attachment's download has got.
///
/// Keyed by `Attachment.id` in `ChatSceneState.downloads`; an absent key is
/// `.idle`.
public enum AttachmentDownloadState: Equatable, Sendable {
    case idle
    case downloading(AttachmentProgress)
    case done
    case failed(String)
}

/// What a chip can ask for about one attachment: start its download, cancel
/// one in progress, open the finished file, reveal it in Finder, or save a
/// copy elsewhere.
///
/// Supplied only when the backend can download files; a chip with none is a
/// plain label, because a control the seam cannot honour is not drawn.
@MainActor
public struct AttachmentFileActions {
    public var download: (Attachment) -> Void
    public var cancel: (Attachment) -> Void
    public var open: (Attachment) -> Void
    public var reveal: (Attachment) -> Void
    public var saveAs: (Attachment) -> Void

    public init(
        download: @escaping (Attachment) -> Void,
        cancel: @escaping (Attachment) -> Void,
        open: @escaping (Attachment) -> Void,
        reveal: @escaping (Attachment) -> Void,
        saveAs: @escaping (Attachment) -> Void
    ) {
        self.download = download
        self.cancel = cancel
        self.open = open
        self.reveal = reveal
        self.saveAs = saveAs
    }
}
