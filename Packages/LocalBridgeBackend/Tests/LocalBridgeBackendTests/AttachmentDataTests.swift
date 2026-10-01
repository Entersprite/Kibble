import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// `LocalBridgeBackend.attachmentData(_:size:)`, reached through a real
/// `connect()`. The redirect chain is the one `findings.md` §51.2 measured:
/// one 302 from the chat host to `lh3.googleusercontent.com`, which serves
/// the bytes to a request carrying no credentials.
private actor AttachmentTransport: HTTPTransport {
    struct NoStream: Error {}

    private let shell: HTTPResponse
    private let image: HTTPResponse
    private(set) var sent: [HTTPRequest] = []

    init(shell: HTTPResponse, image: HTTPResponse) {
        self.shell = shell
        self.image = image
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        sent.append(request)
        if request.url.path.contains("/mole/world") {
            return shell
        }
        if request.url.path.contains("/api/get_attachment_url") {
            return HTTPResponse(
                status: 302,
                headers: HTTPHeaders([("Location", "https://lh3.googleusercontent.com/fife/x=w1024")]),
                body: Data()
            )
        }
        if request.url.host() == "lh3.googleusercontent.com" {
            return image
        }
        return HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data())
    }

    func stream(_: HTTPRequest) async throws -> HTTPStream {
        throw NoStream()
    }
}

@Suite(.timeLimit(.minutes(1)))
struct AttachmentDataTests {
    private static let cookies = SessionCookies(header: "SID=a; COMPASS=b; OSID=c")!

    private static let png = HTTPResponse(
        status: 200,
        headers: HTTPHeaders([("Content-Type", "image/png")]),
        body: Data([0x89, 0x50, 0x4E, 0x47])
    )

    private static let attachment = ChatKit.Attachment(
        id: "upload-token", name: "a.png", contentType: "image/png"
    )

    private static func transport(image: HTTPResponse = png) -> AttachmentTransport {
        let html = LocalBridgeBackendTests.shell(app: "DynamiteWebUi")
        return AttachmentTransport(
            shell: HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data(html.utf8)),
            image: image
        )
    }

    @Test func theCapabilityIsAdvertised() {
        let backend = LocalBridgeBackend(cookies: Self.cookies, transport: Self.transport())
        #expect(backend.capabilities.canFetchAttachments)
    }

    @Test func beforeConnectItThrowsRatherThanFetching() async {
        let transport = Self.transport()
        let backend = LocalBridgeBackend(cookies: Self.cookies, transport: transport)
        await #expect(throws: ChatError.self) {
            _ = try await backend.attachmentData(Self.attachment, size: .preview)
        }
        #expect(await transport.sent.isEmpty)
    }

    /// Through `any ChatBackend`, the way `SyncEngine` holds it, so the
    /// protocol's refusing default cannot be what answers.
    @Test func afterConnectItReturnsTheFinalHopsBytes() async throws {
        let transport = Self.transport()
        let backend: any ChatBackend = LocalBridgeBackend(cookies: Self.cookies, transport: transport)
        try await backend.connect()
        let data = try await backend.attachmentData(Self.attachment, size: .preview)
        #expect(data == Data([0x89, 0x50, 0x4E, 0x47]))

        let sent = await transport.sent
        let first = try #require(sent.first { $0.url.path().contains("get_attachment_url") })
        let query = URLComponents(url: first.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.first { $0.name == "attachment_token" }?.value == "upload-token")
        #expect(query.first { $0.name == "content_type" }?.value == "image/png")
        #expect(query.first { $0.name == "sz" }?.value == "w1024")
        #expect(first.headers["x-framework-xsrf-token"] != nil)
        let final = try #require(sent.last)
        #expect(final.url.host() == "lh3.googleusercontent.com")
        #expect(final.headers["Cookie"] == nil)
    }

    @Test func theOriginalSizeAsksForTheOriginal() async throws {
        let transport = Self.transport()
        let backend = LocalBridgeBackend(cookies: Self.cookies, transport: transport)
        try await backend.connect()
        _ = try await backend.attachmentData(Self.attachment, size: .original)
        let first = try #require(await transport.sent.first { $0.url.path().contains("get_attachment_url") })
        let query = URLComponents(url: first.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.first { $0.name == "sz" }?.value == "w10000-h10000")
    }

    /// The fetch's failure carries hosts and statuses; the `ChatError` a view
    /// sees carries neither the token nor a URL.
    @Test func aFailedFetchIsAServerErrorWithoutTheToken() async throws {
        let transport = Self.transport(image: HTTPResponse(
            status: 403,
            headers: HTTPHeaders([]),
            body: Data()
        ))
        let backend = LocalBridgeBackend(cookies: Self.cookies, transport: transport)
        try await backend.connect()
        do {
            _ = try await backend.attachmentData(Self.attachment, size: .preview)
            Issue.record("expected the fetch to fail")
        } catch let error as ChatError {
            #expect(error == .server(status: 403, message: "the attachment fetch was refused"))
            #expect(!String(describing: error).contains("upload-token"))
        }
    }

    @Test func afterDisconnectItThrowsAgain() async throws {
        let transport = Self.transport()
        let backend = LocalBridgeBackend(cookies: Self.cookies, transport: transport)
        try await backend.connect()
        await backend.disconnect()
        await #expect(throws: ChatError.self) {
            _ = try await backend.attachmentData(Self.attachment, size: .preview)
        }
    }
}
