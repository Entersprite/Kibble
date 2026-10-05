import Foundation

/// A file the person has chosen to send and that has not been uploaded yet:
/// what a composer stages, and what `ChatBackend.uploadAttachment(_:to:progress:)`
/// uploads.
///
/// **Not part of the wire format, on purpose.** It names a file on this
/// machine, which means nothing to a server. What crosses the wire is the
/// `Attachment` the upload returns, carried by `ChatCommand.sendMessage`.
///
/// The host fills it in, because only the host can read a file: the type
/// from its extension, the size, and a picture's pixel size, so a sent image
/// can reserve its shape before the server says anything.
public struct OutgoingAttachment: Hashable, Sendable, Identifiable {
    /// Chosen by whoever staged it; unique within one composer.
    public var id: String
    public var file: URL
    /// The name the message shows. Usually the file's own.
    public var name: String
    /// A MIME type, `application/octet-stream` when nothing better is known.
    public var contentType: String
    public var byteSize: Int
    public var width: Int?
    public var height: Int?

    public init(
        id: String,
        file: URL,
        name: String,
        contentType: String,
        byteSize: Int,
        width: Int? = nil,
        height: Int? = nil
    ) {
        self.id = id
        self.file = file
        self.name = name
        self.contentType = contentType
        self.byteSize = byteSize
        self.width = width
        self.height = height
    }

    /// The same prefix test `Attachment.isImage` uses.
    public var isImage: Bool {
        contentType.lowercased().hasPrefix("image/")
    }

    /// Google's own limit for one file is 200 MB `[Verify]`; a bigger file is
    /// refused when it is staged, rather than after minutes of uploading.
    public static let maximumByteSize = 200 * 1024 * 1024
}
