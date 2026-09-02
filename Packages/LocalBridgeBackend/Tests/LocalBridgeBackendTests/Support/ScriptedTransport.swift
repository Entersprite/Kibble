import Foundation
import GChatBridgeCore

/// A scripted `HTTPTransport`, so these tests need no network.
///
/// A near-twin of the core's own fake, duplicated rather than shared because
/// `scripts/test.sh` fails any build where test scaffolding is reachable from
/// shipping code - and exporting the core's version would mean shipping it.
/// Thirty lines of duplication is the cheaper side of that trade.
actor ScriptedTransport: HTTPTransport {
    struct Exhausted: Error {}

    /// A body that died rather than ended. The twin of
    /// `FakeHTTPTransport.Dropped`, for the same reason the whole fake is a
    /// twin.
    struct Dropped: Error {}

    /// One scripted streaming response: a head, then body chunks in order.
    struct Script: Sendable {
        let status: Int
        let headers: HTTPHeaders
        let chunks: [String]

        /// Whether the body throws after `chunks` instead of finishing. A body
        /// that ends is ordinary and reopens; a body that throws is a dropped
        /// socket, which is the only thing the channel reconnects from.
        let dropsAfterChunks: Bool

        init(
            status: Int = 200,
            headers: HTTPHeaders = HTTPHeaders([]),
            chunks: [String],
            dropsAfterChunks: Bool = false
        ) {
            self.status = status
            self.headers = headers
            self.chunks = chunks
            self.dropsAfterChunks = dropsAfterChunks
        }
    }

    private var responses: [Result<HTTPResponse, any Error>]
    private var streams: [Script]
    private(set) var sent: [HTTPRequest] = []

    init(_ responses: [Result<HTTPResponse, any Error>], streams: [Script] = []) {
        self.responses = responses
        self.streams = streams
    }

    static func ok(_ body: String, url: URL? = nil) -> Result<HTTPResponse, any Error> {
        .success(
            HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data(body.utf8), url: url)
        )
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        sent.append(request)
        guard !responses.isEmpty else { throw Exhausted() }
        return try responses.removeFirst().get()
    }

    func stream(_ request: HTTPRequest) async throws -> HTTPStream {
        sent.append(request)
        guard !streams.isEmpty else { throw Exhausted() }
        let script = streams.removeFirst()
        return HTTPStream(
            status: script.status,
            headers: script.headers,
            body: AsyncThrowingStream { continuation in
                for chunk in script.chunks {
                    continuation.yield(Data(chunk.utf8))
                }
                continuation.finish(throwing: script.dropsAfterChunks ? Dropped() : nil)
            }
        )
    }
}
