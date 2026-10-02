import Foundation
import Testing
@testable import GChatBridgeCore

/// `HTTPTransport.download` is a requirement with a default, so a transport
/// that implements only `send`/`stream` (`FakeHTTPTransport`) still reaches a
/// working download through `any HTTPTransport` — the same shape
/// `fireAndForget`'s own default already proves.
@Suite("HTTP transport - download")
struct HTTPTransportDownloadTests {
    @Test("the default writes the body to a file the caller owns and returns an empty body")
    func defaultWritesAFile() async throws {
        let transport: any HTTPTransport = FakeHTTPTransport(responses: [
            HTTPResponse(
                status: 200,
                headers: HTTPHeaders([("Content-Type", "application/pdf")]),
                body: Data("PDF".utf8)
            )
        ])
        let seen = ProgressLog()
        let (response, file) = try await transport
            .download(HTTPRequest(url: #require(URL(string: "https://x.test/")))) {
                seen.append($0, $1)
            }
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(response.status == 200)
        #expect(response.body.isEmpty)
        #expect(response.headers["Content-Type"] == "application/pdf")
        #expect(try Data(contentsOf: file) == Data("PDF".utf8))
        #expect(seen.last == .init(written: 3, total: 3))
    }

    @Test("a redirect is written to a file, and reports no progress: its body is not the download")
    func redirectReportsNoProgress() async throws {
        let transport: any HTTPTransport = FakeHTTPTransport(responses: [
            HTTPResponse(
                status: 302,
                headers: HTTPHeaders([("Location", "https://x.test/next")]),
                body: Data()
            )
        ])
        let seen = ProgressLog()
        let (response, file) = try await transport
            .download(HTTPRequest(url: #require(URL(string: "https://x.test/")))) {
                seen.append($0, $1)
            }
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(response.status == 302)
        #expect(seen.values.isEmpty)
    }
}

/// Records `(written, total)` progress pairs thread-safely: `download`'s
/// `progress` parameter is `@escaping @Sendable`, so a conforming transport is
/// free to call it from any executor.
///
/// `NSLock` rather than an actor: this is a plain synchronous recorder, not
/// async state, and `scripts/test.sh`'s portability scan for Darwin-only
/// locking types covers `Sources/GChatBridgeCore` only - never `Tests` - so
/// nothing here threatens the Linux build this package promises.
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
