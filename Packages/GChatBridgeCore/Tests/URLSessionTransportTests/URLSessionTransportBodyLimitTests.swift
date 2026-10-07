import Foundation
import GChatBridgeCore
import GChatBridgeCoreTestSupport
import Testing
@testable import URLSessionTransport

/// `HTTPRequest.maxBodyBytes` (review finding 3): an oversized body is refused
/// at the head when its length is declared, and while reading otherwise, so it
/// is never held whole.
@Suite("URLSession transport body limit")
struct URLSessionTransportBodyLimitTests {
    let stub = StubSession()

    var transport: URLSessionTransport {
        URLSessionTransport(session: stub.session)
    }

    @Test func aBodyWithinTheLimitComesBackWhole() async throws {
        stub.enqueue(.init(status: 200, body: Data(repeating: 7, count: 64)))
        let response = try await transport.send(HTTPRequest(url: stub.baseURL, maxBodyBytes: 64))
        #expect(response.status == 200)
        #expect(response.body == Data(repeating: 7, count: 64))
    }

    @Test func aBodyPastTheLimitIsRefusedWhileReading() async {
        stub.enqueue(.init(status: 200, body: Data(count: 65)))
        await #expect(throws: HTTPBodyTooLarge(limit: 64)) {
            _ = try await transport.send(HTTPRequest(url: stub.baseURL, maxBodyBytes: 64))
        }
    }

    /// The body itself is small: only the head can refuse it.
    @Test func aDeclaredLengthPastTheLimitIsRefusedAtTheHead() async {
        stub.enqueue(.init(status: 200, body: Data(count: 10), headers: ["Content-Length": "1000"]))
        await #expect(throws: HTTPBodyTooLarge(limit: 64)) {
            _ = try await transport.send(HTTPRequest(url: stub.baseURL, maxBodyBytes: 64))
        }
    }
}
