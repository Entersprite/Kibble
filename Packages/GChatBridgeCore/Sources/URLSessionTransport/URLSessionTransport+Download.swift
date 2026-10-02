import Foundation
import GChatBridgeCore

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

public extension URLSessionTransport {
    /// Streams the body to a file in 64 KiB writes, so a 200 MB attachment is
    /// never in memory, with the same redirect refusal `send` uses: a
    /// redirect handed back as a response is how `AttachmentFetch` scopes
    /// credentials per hop. Cancelling the calling task cancels the transfer.
    func download(
        _ request: HTTPRequest,
        progress: @escaping @Sendable (Int, Int?) -> Void
    ) async throws -> (response: HTTPResponse, file: URL) {
        try await download(request, to: HTTPTransportFiles.temporaryFile(), progress: progress)
    }

    /// `download`, writing to `file`: `internal` so a test can name the file
    /// and see that a body which fails part-way leaves nothing there, which a
    /// random temporary name would hide among every other test's files.
    internal func download(
        _ request: HTTPRequest,
        to file: URL,
        progress: @escaping @Sendable (Int, Int?) -> Void
    ) async throws -> (response: HTTPResponse, file: URL) {
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(
                for: Self.urlRequest(from: request),
                delegate: request.followsRedirects ? nil : RefuseRedirects.shared
            )
        } catch {
            throw Self.classify(error)
        }
        let http = try Self.httpResponse(from: response)
        let total = http.expectedContentLength >= 0 ? Int(http.expectedContentLength) : nil
        // A redirect's body is not the download, so it reports nothing.
        let ignored: @Sendable (Int, Int?) -> Void = { _, _ in }
        let reported = (300 ..< 400).contains(http.statusCode) ? ignored : progress
        do {
            try await Self.write(bytes, to: file, total: total, progress: reported)
        } catch {
            try? FileManager.default.removeItem(at: file)
            // `classify` only rewraps a real `URLError`; a `CancellationError`
            // or `TransportFailure.cannotWriteFile` from `openForWriting` is
            // neither, so it already returns both unchanged - see its own
            // `guard let urlError = error as? URLError else { return error }`.
            throw Self.classify(error)
        }
        return (
            HTTPResponse(
                status: http.statusCode,
                headers: Self.headers(of: http),
                body: Data(),
                url: http.url
            ),
            file
        )
    }

    internal static let downloadChunk = 64 * 1024

    /// Creates `file` and opens it for writing, throwing
    /// `TransportFailure.cannotWriteFile` when creation fails - a full disk,
    /// a missing parent directory, a sandbox denial, never anything about
    /// the network. `internal`, not `private`, so
    /// `URLSessionTransportDownloadTests` can drive it directly via
    /// `@testable import`, the same reason `classify` and the
    /// request/response conversions above are internal rather than private:
    /// a test reaching `download` end to end cannot force `createFile` to
    /// fail without also depending on real disk state, so the guard itself
    /// needs its own seam.
    static func openForWriting(_ file: URL) throws -> FileHandle {
        guard FileManager.default.createFile(atPath: file.path(percentEncoded: false), contents: nil) else {
            throw TransportFailure.cannotWriteFile
        }
        return try FileHandle(forWritingTo: file)
    }

    private static func write(
        _ bytes: URLSession.AsyncBytes,
        to file: URL,
        total: Int?,
        progress: @Sendable (Int, Int?) -> Void
    ) async throws {
        let handle = try openForWriting(file)
        defer { try? handle.close() }
        var buffer = Data()
        buffer.reserveCapacity(downloadChunk)
        var written = 0
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count == downloadChunk {
                try handle.write(contentsOf: buffer)
                written += buffer.count
                buffer.removeAll(keepingCapacity: true)
                progress(written, total)
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            written += buffer.count
        }
        progress(written, total)
    }
}
