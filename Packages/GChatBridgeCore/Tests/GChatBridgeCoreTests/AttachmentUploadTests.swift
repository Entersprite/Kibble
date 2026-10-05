import Foundation
import SwiftProtobuf
import Testing
@testable import GChatBridgeCore

/// `AttachmentUpload`: the two requests both references make (purple
/// `googlechat_conversation.c:1866-1890` and `:1780-1850`, maugclib
/// `client.py:275-320`), the credentials each host is sent, and every way the
/// answer can fail to be an upload. All of it is `[Verify]` against the live
/// account until `--probe=upload` runs.
@Suite("Attachment upload")
struct AttachmentUploadTests {
    static let cookieSecret = "lowercasecookiesecret"
    static let xsrfSecret = "lowercasexsrfsecret"
    static let uploadURL = "https://chat.google.com/uploads?upload_id=abc&upload_protocol=resumable"

    static func credentials() -> SessionCredentials {
        SessionCredentials(
            SessionCookies(cookies: [
                SessionCookies.Cookie(name: "SID", value: cookieSecret, domain: ".google.com", path: "/")
            ])!
        )
    }

    static func upload(
        _ transport: FakeHTTPTransport,
        endpoints: ChatEndpoints = ChatEndpoints()
    ) -> AttachmentUpload {
        AttachmentUpload(
            transport: transport, endpoints: endpoints, credentials: credentials(), xsrfToken: xsrfSecret
        )
    }

    static func space(_ id: String = "AAAA1111") -> GroupId {
        var group = GroupId()
        var space = SpaceId()
        space.spaceID = id
        group.spaceID = space
        return group
    }

    static func started(_ location: String? = uploadURL) -> HTTPResponse {
        HTTPResponse(
            status: 200,
            headers: HTTPHeaders(location
                .map { [("x-goog-upload-url", $0), ("x-goog-upload-status", "active")] } ?? []),
            body: Data()
        )
    }

    static func metadata(token: String = "tok") -> UploadMetadata {
        var metadata = UploadMetadata()
        metadata.attachmentToken = token
        metadata.contentName = "photo.png"
        metadata.contentType = "image/png"
        return metadata
    }

    static func finalized(
        _ metadata: UploadMetadata = metadata(),
        base64: Bool = true
    ) throws -> HTTPResponse {
        let bytes = try metadata.serializedData()
        return HTTPResponse(
            status: 200,
            headers: HTTPHeaders([("x-goog-upload-status", "final")]),
            body: base64 ? Data(bytes.base64EncodedString().utf8) : bytes
        )
    }

    static func file(_ contents: String = "PNGBYTES") throws -> URL {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("upload-\(UUID().uuidString)")
        try Data(contents.utf8).write(to: file)
        return file
    }

    static func run(
        _ transport: FakeHTTPTransport,
        name: String = "photo.png",
        endpoints: ChatEndpoints = ChatEndpoints(),
        includesAPIKey: Bool = false
    ) async throws(AttachmentUploadFailure) -> UploadMetadata {
        let file: URL
        do {
            file = try Self.file()
        } catch {
            fatalError("could not write the fixture file")
        }
        defer { try? FileManager.default.removeItem(at: file) }
        return try await upload(transport, endpoints: endpoints).upload(
            UploadFile(url: file, name: name, contentType: "image/png", byteCount: 8),
            group: space(), includesAPIKey: includesAPIKey
        ) { _, _ in }
    }

    // MARK: - The two requests

    @Test("the start is a POST to /uploads naming the group, with the upload's headers")
    func startRequest() async throws {
        let transport = try FakeHTTPTransport(responses: [Self.started(), Self.finalized()])
        _ = try await Self.run(transport)
        let start = try #require(await transport.sent.first)
        #expect(start.method == .post)
        #expect(start.url.absoluteString == "https://chat.google.com/u/0/uploads?group_id=AAAA1111")
        #expect(start.headers["x-goog-upload-protocol"] == "resumable")
        #expect(start.headers["x-goog-upload-command"] == "start")
        #expect(start.headers["x-goog-upload-content-length"] == "8")
        #expect(start.headers["x-goog-upload-content-type"] == "image/png")
        #expect(start.headers["x-goog-upload-file-name"] == "photo.png")
        #expect(start.headers["User-Agent"] == ChatEndpoints.defaultUserAgent)
        #expect(start.headers["x-framework-xsrf-token"] == Self.xsrfSecret)
        #expect(start.headers["Cookie"]?.contains(Self.cookieSecret) == true)
        #expect(start.followsRedirects == false)
        #expect(start.body == nil)
    }

    @Test("a DM's group id is its dm id, and no account segment is honoured")
    func dmAndNoAccount() async throws {
        let transport = try FakeHTTPTransport(responses: [Self.started(), Self.finalized()])
        var group = GroupId()
        var dm = DmId()
        dm.dmID = "dm-77"
        group.dmID = dm
        let file = try Self.file()
        defer { try? FileManager.default.removeItem(at: file) }
        _ = try await Self.upload(transport, endpoints: ChatEndpoints(account: .none)).upload(
            UploadFile(url: file, name: "a", contentType: "text/plain", byteCount: 8), group: group
        ) { _, _ in }
        let start = try #require(await transport.sent.first)
        #expect(start.url.absoluteString == "https://chat.google.com/uploads?group_id=dm-77")
    }

    @Test("maugclib's shape adds alt and the API key")
    func maugclibShape() async throws {
        let transport = try FakeHTTPTransport(responses: [Self.started(), Self.finalized()])
        _ = try await Self.run(transport, includesAPIKey: true)
        let start = try #require(await transport.sent.first)
        #expect(start.url.query() == "group_id=AAAA1111&alt=&key=\(APIRequests.defaultAPIKey)")
    }

    @Test("the bytes are a PUT to the address the start answered with, finalized at offset 0")
    func finalizeRequest() async throws {
        let transport = try FakeHTTPTransport(responses: [Self.started(), Self.finalized()])
        _ = try await Self.run(transport)
        let sent = await transport.sent
        #expect(sent.count == 2)
        let put = try #require(sent.last)
        #expect(put.method == .put)
        #expect(put.url.absoluteString == Self.uploadURL)
        #expect(put.headers["x-goog-upload-command"] == "upload, finalize")
        #expect(put.headers["x-goog-upload-protocol"] == "resumable")
        #expect(put.headers["x-goog-upload-offset"] == "0")
        #expect(put.headers["Cookie"]?.contains(Self.cookieSecret) == true)
        #expect(put.headers["x-framework-xsrf-token"] == Self.xsrfSecret)
        #expect(put.body == Data("PNGBYTES".utf8))
        #expect(put.followsRedirects == false)
    }

    /// Google stores the header verbatim (`findings.md` §55.4), so a name is
    /// sent as itself, never percent-encoded.
    @Test("a name outside ASCII is sent as itself, a percent sign included")
    func nonASCIIName() async throws {
        let transport = try FakeHTTPTransport(responses: [Self.started(), Self.finalized()])
        _ = try await Self.run(transport, name: "Résumé 100% 9.41\u{202F}PM.pdf")
        let start = try #require(await transport.sent.first)
        #expect(start.headers["x-goog-upload-file-name"] == "Résumé 100% 9.41\u{202F}PM.pdf")
    }

    /// The owner's `Órarend2.pdf` arrived as `O%CC%81rarend2.pdf`: macOS's
    /// decomposed `O` plus U+0301.
    @Test("a decomposed name is sent precomposed")
    func decomposedName() async throws {
        let transport = try FakeHTTPTransport(responses: [Self.started(), Self.finalized()])
        _ = try await Self.run(transport, name: "O\u{301}rarend2.pdf")
        let start = try #require(await transport.sent.first)
        let sent = try #require(start.headers["x-goog-upload-file-name"])
        #expect(sent.unicodeScalars.map(\.value) == "\u{D3}rarend2.pdf".unicodeScalars.map(\.value))
    }

    @Test("a control character cannot end the header early")
    func controlCharacters() async throws {
        let transport = try FakeHTTPTransport(responses: [Self.started(), Self.finalized()])
        _ = try await Self.run(transport, name: "a\r\nX-Evil: 1\t.pdf")
        let start = try #require(await transport.sent.first)
        #expect(start.headers["x-goog-upload-file-name"] == "a  X-Evil: 1 .pdf")
    }

    // MARK: - The answer

    @Test("the metadata is read from base64, as both references read it")
    func base64Metadata() async throws {
        let transport = try FakeHTTPTransport(responses: [Self.started(), Self.finalized(base64: true)])
        let metadata = try await Self.run(transport)
        #expect(metadata.attachmentToken == "tok")
        #expect(metadata.contentType == "image/png")
    }

    @Test("and from raw bytes, as every /api/ answer arrives (findings.md §3.6)")
    func rawMetadata() async throws {
        let transport = try FakeHTTPTransport(responses: [Self.started(), Self.finalized(base64: false)])
        let metadata = try await Self.run(transport)
        #expect(metadata.attachmentToken == "tok")
    }

    @Test("an answer with no attachment token is not an upload")
    func missingToken() async throws {
        let transport = try FakeHTTPTransport(responses: [
            Self.started(),
            Self.finalized(Self.metadata(token: ""))
        ])
        await #expect(throws: AttachmentUploadFailure(reason: .noAttachmentToken)) {
            _ = try await Self.run(transport)
        }
    }

    @Test("a page instead of metadata is not an upload")
    func pageIsNotMetadata() async throws {
        let page = HTTPResponse(
            status: 200, headers: HTTPHeaders([("Content-Type", "text/html")]), body: Data("<html>".utf8)
        )
        let transport = FakeHTTPTransport(responses: [Self.started(), page])
        await #expect(throws: AttachmentUploadFailure.self) {
            _ = try await Self.run(transport)
        }
    }

    // MARK: - Refusals

    /// Auth failure is HTTP 200 on this protocol, so an answer without the
    /// address is how a signed-out session presents itself here.
    @Test("a start answered without an upload address stops before any bytes are sent")
    func noUploadURL() async throws {
        let page = HTTPResponse(
            status: 200, headers: HTTPHeaders([("Content-Type", "text/html")]), body: Data("<html>".utf8)
        )
        let transport = FakeHTTPTransport(responses: [page])
        do {
            _ = try await Self.run(transport)
            Issue.record("expected a failure")
        } catch {
            #expect(error.reason == .noUploadURL)
            #expect(error.refusal?.contentType == "text/html")
        }
        #expect(await transport.sent.count == 1)
    }

    @Test("a refused start is its status")
    func startRefused() async throws {
        let transport = FakeHTTPTransport(responses: [HTTPResponse(
            status: 403,
            headers: HTTPHeaders([]),
            body: Data()
        )])
        await #expect(throws: AttachmentUploadFailure(
            reason: .startRefused(403), refusal: .init(contentType: nil, bodyBytes: 0, headerNames: [])
        )) {
            _ = try await Self.run(transport)
        }
    }

    @Test("a start redirected to sign-in is an expired session")
    func signInRedirect() async throws {
        let transport = FakeHTTPTransport(responses: [HTTPResponse(
            status: 302,
            headers: HTTPHeaders([("Location", "https://accounts.google.com/ServiceLogin")]),
            body: Data()
        )])
        await #expect(throws: AttachmentUploadFailure(reason: .signInRedirect)) {
            _ = try await Self.run(transport)
        }
    }

    @Test("a refused PUT is its status")
    func uploadRefused() async throws {
        let transport = FakeHTTPTransport(responses: [
            Self.started(), HTTPResponse(status: 400, headers: HTTPHeaders([]), body: Data())
        ])
        do {
            _ = try await Self.run(transport)
            Issue.record("expected a failure")
        } catch {
            #expect(error.reason == .uploadRefused(400))
        }
    }

    /// The credential guard: the address comes from a response header, and
    /// the PUT would carry the session's cookies to wherever it names.
    @Test(arguments: [
        "https://evilgoogle.com/upload",
        "https://google.com.evil.example/upload",
        "http://chat.google.com/uploads?upload_id=abc",
        "https://lh3.googleusercontent.com/upload",
        "not a url at all"
    ])
    func offDomainUploadURLIsRefused(_ location: String) async throws {
        let transport = FakeHTTPTransport(responses: [Self.started(location)])
        do {
            _ = try await Self.run(transport)
            Issue.record("expected a failure")
        } catch {
            #expect(error.reason == .uploadURLRefused)
        }
        #expect(await transport.sent.count == 1)
    }

    /// A sibling Google host is sent only the cookies its domain admits, and
    /// never the xsrf token, which is the chat host's alone.
    @Test("an upload address on a Google sibling gets its cookies but not the xsrf token")
    func siblingHost() async throws {
        let transport = try FakeHTTPTransport(responses: [
            Self.started("https://chat-upload.google.com/upload?id=1"), Self.finalized()
        ])
        _ = try await Self.run(transport)
        let put = try #require(await transport.sent.last)
        #expect(put.url.host() == "chat-upload.google.com")
        #expect(put.headers["Cookie"]?.contains(Self.cookieSecret) == true)
        #expect(put.headers["x-framework-xsrf-token"] == nil)
    }

    @Test("Set-Cookie from the start is absorbed into the jar")
    func absorbsRotation() async throws {
        let credentials = Self.credentials()
        let rotated = HTTPResponse(
            status: 200,
            headers: HTTPHeaders([
                ("x-goog-upload-url", Self.uploadURL),
                ("Set-Cookie", "SIDCC=rotatedvalue; Domain=.google.com; Path=/; Secure")
            ]),
            body: Data()
        )
        let transport = try FakeHTTPTransport(responses: [rotated, Self.finalized()])
        let file = try Self.file()
        defer { try? FileManager.default.removeItem(at: file) }
        _ = try await AttachmentUpload(
            transport: transport, endpoints: ChatEndpoints(), credentials: credentials,
            xsrfToken: Self.xsrfSecret
        ).upload(
            UploadFile(url: file, name: "a", contentType: "image/png", byteCount: 8), group: Self.space()
        ) { _, _ in }
        let put = try #require(await transport.sent.last)
        #expect(put.headers["Cookie"]?.contains("rotatedvalue") == true)
    }

    @Test("a transport failure is classified, never the error itself")
    func transportFailure() async throws {
        let transport = FakeHTTPTransport(responses: [])
        await #expect(throws: AttachmentUploadFailure(reason: .transport(nil))) {
            _ = try await Self.run(transport)
        }
    }
}
