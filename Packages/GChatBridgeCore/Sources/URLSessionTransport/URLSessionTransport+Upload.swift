import Foundation
import GChatBridgeCore

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

public extension URLSessionTransport {
    /// Streams the body from `file`, so a 200 MB upload is never in memory,
    /// with the same redirect refusal `send` uses: a redirect handed back as a
    /// response is how `AttachmentUpload` keeps its credentials to the hosts it
    /// chose. Cancelling the calling task cancels the transfer.
    func upload(
        _ request: HTTPRequest,
        fromFile file: URL,
        progress: @escaping @Sendable (Int, Int?) -> Void
    ) async throws -> HTTPResponse {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.upload(
                for: Self.urlRequest(from: request),
                fromFile: file,
                delegate: UploadDelegate(refusesRedirects: !request.followsRedirects, progress: progress)
            )
        } catch {
            throw Self.classify(error)
        }
        let http = try Self.httpResponse(from: response)
        // The loading system reports progress while it sends, and not
        // necessarily the last chunk, so an accepted body always ends with
        // the whole file. A redirect's never does: nothing was uploaded.
        if !(300 ..< 400).contains(http.statusCode),
           let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            progress(size, size)
        }
        return HTTPResponse(
            status: http.statusCode,
            headers: Self.headers(of: http),
            body: data,
            url: http.url
        )
    }
}

/// The per-task delegate behind `upload`: `RefuseRedirects`' refusal when the
/// request asks for it, and the bytes sent so far.
final class UploadDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private let refusesRedirects: Bool
    private let progress: @Sendable (Int, Int?) -> Void

    init(refusesRedirects: Bool, progress: @escaping @Sendable (Int, Int?) -> Void) {
        self.refusesRedirects = refusesRedirects
        self.progress = progress
    }

    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        refusesRedirects ? nil : request
    }

    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        didSendBodyData _: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        progress(Int(totalBytesSent), totalBytesExpectedToSend > 0 ? Int(totalBytesExpectedToSend) : nil)
    }
}
