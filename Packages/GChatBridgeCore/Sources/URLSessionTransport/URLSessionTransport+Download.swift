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
        let file = HTTPTransportFiles.temporaryFile()
        do {
            try await Self.write(bytes, to: file, total: total, progress: progress)
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error is CancellationError || error is TransportFailure ? error : Self.classify(error)
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

    private static func write(
        _ bytes: URLSession.AsyncBytes,
        to file: URL,
        total: Int?,
        progress: @Sendable (Int, Int?) -> Void
    ) async throws {
        guard FileManager.default.createFile(atPath: file.path(percentEncoded: false), contents: nil) else {
            throw TransportFailure.cannotWriteFile
        }
        let handle = try FileHandle(forWritingTo: file)
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
