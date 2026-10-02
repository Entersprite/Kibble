import Foundation

/// A file attachment written to disk, and the chain that produced it.
public struct DownloadedAttachment: Sendable, Hashable {
    /// Owned by the caller, which moves or deletes it.
    public let file: URL
    public let byteCount: Int
    public let contentType: String?
    /// Carries the file's name, so it is reported by presence only.
    public let contentDisposition: String?
    public let hops: [AttachmentHop]
}

public extension AttachmentFetch {
    /// A file upload's bytes, streamed to a file through `HTTPTransport.download`
    /// along the same walk as `fetch` (`walk(from:pageIsAnAnswer:style:exchange:)`).
    /// On any failure no file is left behind.
    func download(
        token: String,
        contentType: String,
        progress: @escaping @Sendable (Int, Int?) -> Void
    ) async throws(AttachmentFetchFailure) -> DownloadedAttachment {
        let transport = transport
        let walked = try await walk(
            from: firstURL(token: token, contentType: contentType, variant: .file),
            pageIsAnAnswer: Self.isPage(contentType),
            style: .app
        ) { request in
            let (response, file) = try await transport.download(request, progress: progress)
            return (response, file)
        }
        guard let file = walked.file else {
            throw AttachmentFetchFailure(reason: .transport(nil), hops: walked.hops)
        }
        // A size that cannot be read is not a size of zero, which would
        // report a whole file as truncated.
        let attributes = try? FileManager.default.attributesOfItem(atPath: file.path(percentEncoded: false))
        guard let received = (attributes?[.size] as? NSNumber)?.intValue else {
            Self.discard(file)
            throw AttachmentFetchFailure(reason: .transport(nil), hops: walked.hops)
        }
        if let expected = Self.statedLength(walked.response.headers), expected != received {
            Self.discard(file)
            throw AttachmentFetchFailure(
                reason: .truncated(expected: expected, received: received),
                hops: walked.hops
            )
        }
        return DownloadedAttachment(
            file: file,
            byteCount: received,
            contentType: walked.response.headers["Content-Type"],
            contentDisposition: walked.response.headers["Content-Disposition"],
            hops: walked.hops
        )
    }

    /// `Content-Length`, unless a `Content-Encoding` other than `identity`
    /// makes it the size on the wire rather than on disk: the transport decodes
    /// gzip, so comparing the two would call a whole file truncated.
    internal static func statedLength(_ headers: HTTPHeaders) -> Int? {
        if let encoding = headers["Content-Encoding"]?.lowercased(), encoding != "identity" {
            return nil
        }
        return headers["Content-Length"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }
}
