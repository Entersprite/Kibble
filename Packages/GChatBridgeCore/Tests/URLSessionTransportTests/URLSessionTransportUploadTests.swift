import Foundation
import GChatBridgeCore
import GChatBridgeCoreTestSupport
import Testing
@testable import URLSessionTransport

/// `URLSessionTransport`'s streaming override of `HTTPTransport.upload`: the
/// body comes from the file, the method and headers are the request's, and a
/// redirect is refused the way `send` refuses one.
@Suite("URLSession transport - upload")
struct URLSessionTransportUploadTests {
    let stub = StubSession()

    var transport: URLSessionTransport {
        URLSessionTransport(session: stub.session)
    }

    @Test("the file's bytes are the body, under the request's method and headers")
    func sendsTheFile() async throws {
        let file = try Self.file(Data(repeating: 9, count: 100_000))
        defer { try? FileManager.default.removeItem(at: file) }
        stub.enqueue(StubURLProtocol.Stub(status: 200, body: Data("META".utf8)))
        let seen = ProgressLog()
        let response = try await transport.upload(
            HTTPRequest(
                method: .put,
                url: stub.baseURL,
                headers: HTTPHeaders([("x-goog-upload-offset", "0")])
            ),
            fromFile: file
        ) { seen.append($0, $1) }
        #expect(response.status == 200)
        #expect(response.body == Data("META".utf8))
        let recorded = try #require(stub.recordings.first)
        #expect(recorded.request.httpMethod == "PUT")
        #expect(recorded.request.value(forHTTPHeaderField: "x-goog-upload-offset") == "0")
        #expect(recorded.body == Data(repeating: 9, count: 100_000))
        #expect(seen.last?.written == 100_000)
    }

    @Test("an upload that does not follow redirects gets the 3xx itself")
    func refusesRedirects() async throws {
        let file = try Self.file(Data("x".utf8))
        defer { try? FileManager.default.removeItem(at: file) }
        stub.enqueue(StubURLProtocol.Stub(status: 302, headers: ["Location": "/next"]))
        stub.enqueue(StubURLProtocol.Stub(status: 200))
        let response = try await transport.upload(
            HTTPRequest(method: .put, url: stub.baseURL, followsRedirects: false), fromFile: file
        ) { _, _ in }
        #expect(response.status == 302)
        #expect(stub.requests.count == 1)
    }

    @Test("a transport failure is classified")
    func failureIsClassified() async throws {
        let file = try Self.file(Data("x".utf8))
        defer { try? FileManager.default.removeItem(at: file) }
        stub.enqueueFailure(.timedOut)
        await #expect(throws: ClassifiedTransportFailure.self) {
            _ = try await transport
                .upload(HTTPRequest(method: .put, url: stub.baseURL), fromFile: file) { _, _ in }
        }
    }

    private static func file(_ data: Data) throws -> URL {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("upload-\(UUID().uuidString)")
        try data.write(to: file)
        return file
    }
}
