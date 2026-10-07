import Foundation
import GChatBridgeCore

extension URLSessionTransport {
    /// `send` with a ceiling on the body (`HTTPRequest.maxBodyBytes`, review finding 3).
    /// `data(for:)` would hold the whole body before anything could look at it, so
    /// this reads through `bytes(for:)`, as `stream()` does: refused at the head
    /// when the declared length is over the limit, and the moment the bytes pass it.
    func send(_ request: HTTPRequest, limit: Int) async throws -> HTTPResponse {
        let startedAt = ContinuousClock.now
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(
                for: Self.urlRequest(from: request),
                delegate: request.followsRedirects ? nil : RefuseRedirects.shared
            )
        } catch {
            let classified = Self.classify(error)
            traceUnaryCall(
                channelTrace, request, startedAt, .error(Self.safeTraceDescription(classified))
            )
            throw classified
        }
        let http = try Self.httpResponse(from: response)
        guard http.expectedContentLength <= Int64(limit) else {
            bytes.task.cancel()
            throw HTTPBodyTooLarge(limit: limit)
        }
        let data = try await Self.collect(bytes, limit: limit)
        traceUnaryCall(channelTrace, request, startedAt, .completed(status: http.statusCode), data)
        return HTTPResponse(
            status: http.statusCode,
            headers: Self.headers(of: http),
            body: data,
            url: http.url
        )
    }

    /// The body, up to `limit` bytes; one byte more cancels the task and throws.
    private static func collect(_ bytes: URLSession.AsyncBytes, limit: Int) async throws -> Data {
        var data = Data()
        do {
            for try await byte in bytes {
                guard data.count < limit else {
                    bytes.task.cancel()
                    throw HTTPBodyTooLarge(limit: limit)
                }
                data.append(byte)
            }
        } catch let tooLarge as HTTPBodyTooLarge {
            throw tooLarge
        } catch {
            throw classify(error)
        }
        return data
    }
}
