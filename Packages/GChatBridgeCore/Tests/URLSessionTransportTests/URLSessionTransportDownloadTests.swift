import Foundation
import GChatBridgeCore
import GChatBridgeCoreTestSupport
import Testing
@testable import URLSessionTransport

/// `URLSessionTransport`'s streaming override of `HTTPTransport.download`:
/// the body never sits in memory, it is written to disk in 64 KiB writes, and
/// a redirect is refused the same way `send` refuses one.
@Suite("URLSession transport - download")
struct URLSessionTransportDownloadTests {
    let stub = StubSession()

    var transport: URLSessionTransport {
        URLSessionTransport(session: stub.session)
    }

    @Test("a 200 is streamed to a file, with progress reaching the length")
    func streamsToAFile() async throws {
        let body = Data(repeating: 7, count: 200_000) // more than one 64 KiB chunk
        stub.enqueue(StubURLProtocol.Stub(
            status: 200,
            body: body,
            headers: ["Content-Length": "\(body.count)"]
        ))
        let seen = ProgressLog()
        let (response, file) = try await transport.download(HTTPRequest(url: stub.baseURL)) { seen.append(
            $0,
            $1
        ) }
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(response.status == 200)
        #expect(response.body.isEmpty)
        #expect(try Data(contentsOf: file) == body)
        #expect(seen.values.count >= 3)
        #expect(seen.last?.written == body.count)
    }

    @Test("a refusal is a response, not a throw, and its empty body is still a file")
    func refusalIsAResponse() async throws {
        stub.enqueue(StubURLProtocol.Stub(status: 403, body: Data()))
        let (response, file) = try await transport.download(HTTPRequest(url: stub.baseURL)) { _, _ in }
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(response.status == 403)
        #expect(response.body.isEmpty)
        #expect(FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
        #expect(try Data(contentsOf: file).isEmpty)
    }

    @Test("a transport failure is classified and leaves no file")
    func failureIsClassified() async throws {
        stub.enqueueFailure(.timedOut)
        await #expect(throws: ClassifiedTransportFailure.self) {
            _ = try await transport.download(HTTPRequest(url: stub.baseURL)) { _, _ in }
        }
    }
}

/// `HTTPRequest.followsRedirects == false`: whether `download` gets the same
/// redirect refusal `send` already has, proven the same way
/// `URLSessionTransportRedirectTests` proves it for `send` - a stubbed 3xx
/// really is reported as a redirect to the loading system
/// (`StubURLProtocol.startLoading()`'s `wasRedirectedTo`), so a per-task
/// delegate that refuses it is a real mechanism, not a fake.
@Suite("URLSession transport - download redirects")
struct URLSessionTransportDownloadRedirectTests {
    let stub = StubSession()

    var transport: URLSessionTransport {
        URLSessionTransport(session: stub.session)
    }

    @Test("a download that does not follow redirects gets the 3xx itself, as a file")
    func refusesWhenAsked() async throws {
        stub.enqueue(StubURLProtocol.Stub(status: 302, headers: ["Location": "/next"]))
        stub.enqueue(StubURLProtocol.Stub(status: 200, body: Data(#"{"landed":true}"#.utf8)))
        let (response, file) = try await transport.download(
            HTTPRequest(url: stub.baseURL, followsRedirects: false)
        ) { _, _ in }
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(response.status == 302)
        #expect(response.headers["Location"] == "/next")
        #expect(stub.requests.count == 1)
    }
}

/// Records `(written, total)` progress pairs thread-safely, mirroring
/// `HTTPTransportDownloadTests.ProgressLog` - duplicated rather than shared
/// because `GChatBridgeCoreTests` and `URLSessionTransportTests` are separate
/// test targets with no common dependency to hold a shared test helper.
final class ProgressLog: @unchecked Sendable {
    struct Entry: Equatable {
        let written: Int
        let total: Int?
    }

    private let lock = NSLock()
    private var entries: [Entry] = []

    func append(_ written: Int, _ total: Int?) {
        lock.withLock { entries.append(Entry(written: written, total: total)) }
    }

    var last: Entry? {
        lock.withLock { entries.last }
    }

    var values: [Entry] {
        lock.withLock { entries }
    }
}
