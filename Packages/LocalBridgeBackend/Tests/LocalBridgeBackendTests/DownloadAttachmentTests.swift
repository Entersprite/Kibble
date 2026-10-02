import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// `LocalBridgeBackend.downloadAttachment(_:to:progress:)`, reached through a
/// real `connect()`. The chain is §52.10's shape: one 302 from the chat host
/// to `chat.usercontent.google.com`, which serves the file to the
/// `.google.com` cookies. `download` is the protocol's default, through
/// `send`.
private actor DownloadTransport: HTTPTransport {
    struct NoStream: Error {}

    private let shell: HTTPResponse
    private let file: HTTPResponse
    private(set) var sent: [HTTPRequest] = []

    init(shell: HTTPResponse, file: HTTPResponse) {
        self.shell = shell
        self.file = file
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        sent.append(request)
        if request.url.path.contains("/mole/world") {
            return shell
        }
        if request.url.path.contains("/api/get_attachment_url") {
            return HTTPResponse(
                status: 302,
                headers: HTTPHeaders([("Location", "https://chat.usercontent.google.com/download/x")]),
                body: Data()
            )
        }
        if request.url.host() == "chat.usercontent.google.com" {
            return file
        }
        return HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data())
    }

    func stream(_: HTTPRequest) async throws -> HTTPStream {
        throw NoStream()
    }

    var askedForAnAttachmentURL: Bool {
        sent.contains { $0.url.path().contains("get_attachment_url") }
    }
}

/// Progress reports, from whatever executor the transport calls on.
private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var reports: [AttachmentProgress] = []

    func append(_ report: AttachmentProgress) {
        lock.withLock { reports.append(report) }
    }

    var last: AttachmentProgress? {
        lock.withLock { reports.last }
    }
}

@Suite(.timeLimit(.minutes(1)))
struct DownloadAttachmentTests {
    private static let scoped = SessionCookies(cookies: [
        SessionCookies.Cookie(name: "SID", value: "lowercasesid", domain: ".google.com", path: "/"),
        SessionCookies.Cookie(
            name: "COMPASS",
            value: "lowercasecompass",
            domain: "chat.google.com",
            path: "/"
        )
    ])!

    private static let legacy = SessionCookies(header: "SID=a; COMPASS=b; OSID=c")!

    private static let pdf = HTTPResponse(
        status: 200,
        headers: HTTPHeaders([("Content-Type", "application/pdf"), ("Content-Length", "4")]),
        body: Data("%PDF".utf8)
    )

    private static let attachment = ChatKit.Attachment(
        id: "upload-token", name: "a.pdf", contentType: "application/pdf"
    )

    private static func transport(file: HTTPResponse = pdf) -> DownloadTransport {
        let html = LocalBridgeBackendTests.shell(app: "DynamiteWebUi")
        return DownloadTransport(
            shell: HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data(html.utf8)),
            file: file
        )
    }

    private static func destination() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("download-test-\(UUID().uuidString).pdf")
    }

    private static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    @Test func theCapabilityIsAdvertised() {
        let backend = LocalBridgeBackend(cookies: Self.scoped, transport: Self.transport())
        #expect(backend.capabilities.canDownloadFiles == true)
    }

    /// Through `any ChatBackend`, the way `SyncEngine` holds it, so the
    /// protocol's refusing default cannot be what answers.
    @Test func aDownloadLandsAtTheDestinationAndReportsItsSize() async throws {
        let backend: any ChatBackend = LocalBridgeBackend(cookies: Self.scoped, transport: Self.transport())
        try await backend.connect()
        let destination = Self.destination()
        defer { try? FileManager.default.removeItem(at: destination) }
        let progress = ProgressRecorder()
        try await backend.downloadAttachment(Self.attachment, to: destination) { progress.append($0) }
        #expect(try Data(contentsOf: destination) == Data("%PDF".utf8))
        #expect(progress.last?.bytesReceived == 4)
    }

    /// A session stored before cookie domains were kept sends the download
    /// host nothing, so it is refused before any request is made.
    @Test func aLegacySessionIsAskedToSignInWithoutARequest() async throws {
        let transport = Self.transport()
        let backend = LocalBridgeBackend(cookies: Self.legacy, transport: transport)
        try await backend.connect()
        let destination = Self.destination()
        defer { try? FileManager.default.removeItem(at: destination) }
        do {
            try await backend.downloadAttachment(Self.attachment, to: destination) { _ in }
            Issue.record("expected the download to be refused")
        } catch let error as ChatError {
            guard case .signInRequired = error else {
                Issue.record("expected signInRequired, got \(error)")
                return
            }
        }
        #expect(await !transport.askedForAnAttachmentURL)
        #expect(!Self.exists(destination))
    }

    @Test func aRefusalIsAServerErrorAndNothingIsWritten() async throws {
        let transport = Self.transport(file: HTTPResponse(
            status: 403,
            headers: HTTPHeaders([]),
            body: Data()
        ))
        let backend = LocalBridgeBackend(cookies: Self.scoped, transport: transport)
        try await backend.connect()
        let destination = Self.destination()
        do {
            try await backend.downloadAttachment(Self.attachment, to: destination) { _ in }
            Issue.record("expected the download to fail")
        } catch let error as ChatError {
            #expect(error == .server(status: 403, message: "the attachment fetch was refused"))
            #expect(!String(describing: error).contains("upload-token"))
        }
        #expect(!Self.exists(destination))
    }

    @Test func anExistingDestinationIsRefusedAndLeftAlone() async throws {
        let backend = LocalBridgeBackend(cookies: Self.scoped, transport: Self.transport())
        try await backend.connect()
        let destination = Self.destination()
        defer { try? FileManager.default.removeItem(at: destination) }
        try Data("mine".utf8).write(to: destination)
        await #expect(throws: ChatError.self) {
            try await backend.downloadAttachment(Self.attachment, to: destination) { _ in }
        }
        #expect(try Data(contentsOf: destination) == Data("mine".utf8))
    }
}
