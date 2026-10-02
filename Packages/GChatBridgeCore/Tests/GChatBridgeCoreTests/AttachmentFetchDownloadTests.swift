import Foundation
import Testing
@testable import GChatBridgeCore

/// `FakeHTTPTransport` with every file `download` hands out recorded, so a
/// test can ask which of them the walk left on disk. `download` goes through
/// the protocol's own default, the same one `FakeHTTPTransport` reaches.
actor RecordingDownloadTransport: HTTPTransport {
    private let inner: FakeHTTPTransport
    private(set) var files: [URL] = []

    init(_ responses: [HTTPResponse]) {
        inner = FakeHTTPTransport(responses: responses)
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        try await inner.send(request)
    }

    func stream(_ request: HTTPRequest) async throws -> HTTPStream {
        try await inner.stream(request)
    }

    func download(
        _ request: HTTPRequest,
        progress: @escaping @Sendable (Int, Int?) -> Void
    ) async throws -> (response: HTTPResponse, file: URL) {
        let answer = try await inner.download(request, progress: progress)
        files.append(answer.file)
        return answer
    }

    /// Every recorded file still on disk.
    var remaining: [URL] {
        files.filter { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
    }

    func cleanUp() {
        for file in files {
            try? FileManager.default.removeItem(at: file)
        }
    }
}

/// `AttachmentFetch.download`: the same walk as `fetch`, with each hop's
/// body written to a file, and no file left behind on any failure.
@Suite("Attachment fetch - download")
struct AttachmentFetchDownloadTests {
    static let downloadHost = "https://chat.usercontent.google.com/download/x"

    static func fetch(_ transport: RecordingDownloadTransport) -> AttachmentFetch {
        AttachmentFetch(
            transport: transport,
            endpoints: AttachmentFetchTests.endpoints,
            credentials: AttachmentFetchTests.credentials(),
            xsrfToken: AttachmentFetchTests.xsrfSecret
        )
    }

    static func file(
        _ body: String,
        contentType: String = "application/pdf",
        extra: [(String, String)] = []
    ) -> HTTPResponse {
        HTTPResponse(
            status: 200,
            headers: HTTPHeaders([("Content-Type", contentType)] + extra),
            body: Data(body.utf8)
        )
    }

    static func download(
        _ transport: RecordingDownloadTransport,
        contentType: String = "application/pdf"
    ) async throws(AttachmentFetchFailure) -> DownloadedAttachment {
        try await fetch(transport).download(token: "t", contentType: contentType) { _, _ in }
    }

    @Test("a redirect to the download host returns the file, and the redirect's own file is gone")
    func redirectChain() async throws {
        let transport = RecordingDownloadTransport([
            AttachmentFetchTests.redirect(to: Self.downloadHost),
            Self.file("PDF", extra: [("Content-Length", "3")])
        ])
        defer { Task { await transport.cleanUp() } }
        let downloaded = try await Self.download(transport)
        #expect(try Data(contentsOf: downloaded.file) == Data("PDF".utf8))
        #expect(downloaded.byteCount == 3)
        #expect(downloaded.contentType == "application/pdf")
        #expect(downloaded.hops.map(\.host) == ["chat.google.com", "chat.usercontent.google.com"])
        let files = await transport.files
        #expect(files.count == 2)
        #expect(files.last == downloaded.file)
        #expect(await transport.remaining == [downloaded.file])
    }

    @Test("a body shorter than its Content-Length is truncated, and leaves no file")
    func truncated() async {
        let transport = RecordingDownloadTransport([Self.file("PDF", extra: [("Content-Length", "10")])])
        let failure = await #expect(throws: AttachmentFetchFailure.self) {
            try await Self.download(transport)
        }
        #expect(failure?.reason == .truncated(expected: 10, received: 3))
        #expect(await transport.files.count == 1)
        #expect(await transport.remaining.isEmpty)
    }

    /// URLSession decodes gzip, so the stated length is the wire's, not the
    /// file's: comparing them would call every compressed file truncated.
    @Test("a compressed body's Content-Length is not compared with the file")
    func gzipIsAccepted() async throws {
        let transport = RecordingDownloadTransport([
            Self.file("PDF", extra: [("Content-Length", "10"), ("Content-Encoding", "gzip")])
        ])
        defer { Task { await transport.cleanUp() } }
        let downloaded = try await Self.download(transport)
        #expect(downloaded.byteCount == 3)
    }

    @Test("a page where a PDF was expected fails, and leaves no file")
    func pageForAPDF() async {
        let transport = RecordingDownloadTransport([Self.file(
            "<html>sign in</html>",
            contentType: "text/html"
        )])
        let failure = await #expect(throws: AttachmentFetchFailure.self) {
            try await Self.download(transport)
        }
        #expect(failure?.reason == .htmlInsteadOfAttachment)
        #expect(await transport.remaining.isEmpty)
    }

    @Test("an uploaded page downloaded as a file is the file")
    func pageForAPage() async throws {
        let transport = RecordingDownloadTransport([Self.file(
            "<html>notes</html>",
            contentType: "text/html"
        )])
        defer { Task { await transport.cleanUp() } }
        let downloaded = try await Self.download(transport, contentType: "text/html")
        #expect(try Data(contentsOf: downloaded.file) == Data("<html>notes</html>".utf8))
    }

    @Test("a refusal fails with its status, and leaves no file")
    func refused() async {
        let transport = RecordingDownloadTransport([
            HTTPResponse(status: 403, headers: HTTPHeaders([]), body: Data("no".utf8))
        ])
        let failure = await #expect(throws: AttachmentFetchFailure.self) {
            try await Self.download(transport)
        }
        #expect(failure?.reason == .httpStatus(403))
        #expect(await transport.files.count == 1)
        #expect(await transport.remaining.isEmpty)
    }

    @Test("a hop to the sign-in page fails as one, and leaves no file")
    func signIn() async {
        let transport = RecordingDownloadTransport([
            AttachmentFetchTests.redirect(to: "https://accounts.google.com/ServiceLogin?continue=x")
        ])
        let failure = await #expect(throws: AttachmentFetchFailure.self) {
            try await Self.download(transport)
        }
        #expect(failure?.reason == .signInRedirect)
        #expect(await transport.remaining.isEmpty)
    }
}
