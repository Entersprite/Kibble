import Foundation

/// Something attached to a message: an image, a file, a link preview's asset.
///
/// Coding is synthesised, for the reason given on `Reaction`.
public struct Attachment: Codable, Hashable, Sendable {
    /// An opaque, backend-scoped reference to the attachment's data —
    /// **[Verify]** on the internal protocol this is a data ref rather than a
    /// URL, and fetching it is a separate authenticated call. Treat it the way
    /// `Message.ID` is treated: hold it, hand it back, never parse it. It may
    /// be empty if a backend has no such handle.
    public var id: String

    /// The filename as sent. May be empty; may collide within one message.
    public var name: String

    /// A MIME type when the backend knows one. Not an enum: the set is open by
    /// definition and a client only ever pattern-matches a prefix.
    public var contentType: String

    /// `nil` means the size is not known, which is common before download.
    public var byteSize: Int?
    public var downloadURL: URL?
    public var thumbnailURL: URL?

    /// The size the upload declared, in pixels, so a view can reserve the
    /// right shape before the bytes arrive. `nil` when the backend did not say,
    /// which every attachment stored before these existed decodes as.
    public var width: Int?
    public var height: Int?

    public init(
        id: String,
        name: String,
        contentType: String,
        byteSize: Int? = nil,
        downloadURL: URL? = nil,
        thumbnailURL: URL? = nil,
        width: Int? = nil,
        height: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.contentType = contentType
        self.byteSize = byteSize
        self.downloadURL = downloadURL
        self.thumbnailURL = thumbnailURL
        self.width = width
        self.height = height
    }

    /// Whether a client should draw it as a picture. A prefix match, as
    /// `contentType`'s own comment says a client only ever does.
    public var isImage: Bool {
        contentType.lowercased().hasPrefix("image/")
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case contentType
        case byteSize
        case downloadURL
        case thumbnailURL
        case width
        case height
    }
}

/// Which rendition of an attachment's bytes to ask a backend for.
public enum AttachmentSize: String, Sendable, Hashable {
    /// Big enough for a message bubble.
    case preview
    /// As large as the backend will serve.
    case original
}

/// How far a file download has got. `totalBytes` is `nil` when the server
/// sent no length, which a view draws as a spinner rather than a bar.
public struct AttachmentProgress: Sendable, Hashable {
    public var bytesReceived: Int
    public var totalBytes: Int?

    public init(bytesReceived: Int, totalBytes: Int?) {
        self.bytesReceived = bytesReceived
        self.totalBytes = totalBytes
    }
}
