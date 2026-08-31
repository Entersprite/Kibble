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

    public init(
        id: String,
        name: String,
        contentType: String,
        byteSize: Int? = nil,
        downloadURL: URL? = nil,
        thumbnailURL: URL? = nil
    ) {
        self.id = id
        self.name = name
        self.contentType = contentType
        self.byteSize = byteSize
        self.downloadURL = downloadURL
        self.thumbnailURL = thumbnailURL
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case contentType
        case byteSize
        case downloadURL
        case thumbnailURL
    }
}
