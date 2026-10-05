import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// `LocalBridgeBackend.uploadAttachment(_:to:progress:)` and a send that
/// carries what it returned, reached through a real `connect()`. `upload` is
/// the transport protocol's default, through `send`.
private actor UploadTransport: HTTPTransport {
    struct NoStream: Error {}

    private let shell: HTTPResponse
    private let finalized: HTTPResponse
    private(set) var sent: [HTTPRequest] = []

    init(shell: HTTPResponse, finalized: HTTPResponse) {
        self.shell = shell
        self.finalized = finalized
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        sent.append(request)
        if request.url.path.contains("/mole/world") {
            return shell
        }
        if request.method == .put {
            return finalized
        }
        if request.url.path.hasSuffix("/uploads") {
            return HTTPResponse(
                status: 200,
                headers: HTTPHeaders([("x-goog-upload-url", "https://chat.google.com/uploads?upload_id=u1")]),
                body: Data()
            )
        }
        if request.url.path.contains("/api/create_topic") {
            var response = CreateTopicResponse()
            var id = TopicId()
            id.topicID = "t-1"
            response.topic.id = id
            return try HTTPResponse(status: 200, headers: HTTPHeaders([]), body: response.serializedBytes())
        }
        return HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data())
    }

    func stream(_: HTTPRequest) async throws -> HTTPStream {
        throw NoStream()
    }
}

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
struct UploadAttachmentBackendTests {
    private static let cookies = SessionCookies(cookies: [
        SessionCookies.Cookie(name: "SID", value: "lowercasesid", domain: ".google.com", path: "/")
    ])!

    /// What the server answered, with a field no rebuild would produce
    /// (`local_id`), so a send that rebuilt rather than returned it shows.
    private static func serverMetadata() -> UploadMetadata {
        var metadata = UploadMetadata()
        metadata.attachmentToken = "server-token"
        metadata.contentName = "tread.png"
        metadata.contentType = "image/png"
        metadata.localID = "server-local-id"
        return metadata
    }

    private static func transport(_ metadata: UploadMetadata = serverMetadata()) throws -> UploadTransport {
        let html = LocalBridgeBackendTests.shell(app: "DynamiteWebUi")
        let bytes: Data = try metadata.serializedBytes()
        return UploadTransport(
            shell: HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data(html.utf8)),
            finalized: HTTPResponse(
                status: 200,
                headers: HTTPHeaders([]),
                body: Data(bytes.base64EncodedString().utf8)
            )
        )
    }

    private static func staged() throws -> OutgoingAttachment {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("staged-\(UUID().uuidString).png")
        try Data("PNGBYTES".utf8).write(to: file)
        return OutgoingAttachment(
            id: "o-1", file: file, name: "tread.png", contentType: "image/png", byteSize: 8, width: 416,
            height: 300
        )
    }

    private static func space(_ id: String) -> GroupId {
        var group = GroupId()
        var space = SpaceId()
        space.spaceID = id
        group.spaceID = space
        return group
    }

    @Test func theCapabilityIsAdvertised() throws {
        let backend = try LocalBridgeBackend(cookies: Self.cookies, transport: Self.transport())
        #expect(backend.capabilities.canSendAttachments)
    }

    /// Through `any ChatBackend`, the way `SyncEngine` holds it, so the
    /// protocol's refusing default cannot be what answers.
    @Test func anUploadReturnsTheServersAttachmentWithTheStagedSizeAndShape() async throws {
        let transport = try Self.transport()
        let backend: any ChatBackend = LocalBridgeBackend(cookies: Self.cookies, transport: transport)
        try await backend.connect()
        let staged = try Self.staged()
        defer { try? FileManager.default.removeItem(at: staged.file) }
        let progress = ProgressRecorder()
        let uploaded = try await backend
            .uploadAttachment(staged, to: .init("space/s-1")) { progress.append($0) }
        #expect(uploaded == ChatKit.Attachment(
            id: "server-token", name: "tread.png", contentType: "image/png", byteSize: 8, width: 416,
            height: 300
        ))
        #expect(progress.last?.bytesReceived == 8)
        let sent = await transport.sent
        let start = try #require(sent.first { $0.url.path.hasSuffix("/uploads") })
        #expect(start.url.query() == "group_id=s-1")
        #expect(sent.last?.method == .put)
    }

    /// The upload's answer goes back verbatim, as purple sends it.
    @Test func aSendCarriesTheUploadsOwnMetadataAsAnAnnotation() async throws {
        let transport = try Self.transport()
        let backend = LocalBridgeBackend(cookies: Self.cookies, transport: transport)
        try await backend.connect()
        let staged = try Self.staged()
        defer { try? FileManager.default.removeItem(at: staged.file) }
        let uploaded = try await backend.uploadAttachment(staged, to: .init("space/s-1")) { _ in }
        try await backend.send(.sendMessage(
            conversationID: .init("space/s-1"), threadID: nil, text: "caption", localID: "gchat%9",
            attachments: [uploaded]
        ))
        let request = try #require(await transport.sent.first { $0.url.path.contains("/api/create_topic") })
        let expected: Data = try SendRequests.createTopic(
            group: Self.space("s-1"), text: "caption", localID: "gchat%9",
            annotations: [SendRequests.uploadAnnotation(Self.serverMetadata())]
        ).serializedBytes()
        #expect(request.body == expected)
    }

    @Test func anAttachmentThisSessionDidNotUploadIsRebuiltFromTheDomain() async throws {
        let transport = try Self.transport()
        let backend = LocalBridgeBackend(cookies: Self.cookies, transport: transport)
        try await backend.connect()
        let earlier = ChatKit.Attachment(
            id: "earlier-token", name: "a.pdf", contentType: "application/pdf", byteSize: 4
        )
        try await backend.send(.sendMessage(
            conversationID: .init("space/s-1"), threadID: nil, text: "", localID: "l", attachments: [earlier]
        ))
        let request = try #require(await transport.sent.first { $0.url.path.contains("/api/create_topic") })
        let decoded = try CreateTopicRequest(serializedBytes: #require(request.body))
        #expect(decoded.annotations.count == 1)
        #expect(decoded.annotations.first?.uploadMetadata.attachmentToken == "earlier-token")
        #expect(decoded.annotations.first?.uploadMetadata.contentName == "a.pdf")
        #expect(decoded.annotations.first?.uploadMetadata.hasLocalID == false)
    }

    @Test func anUploadBeforeConnectIsRefused() async throws {
        let backend = try LocalBridgeBackend(cookies: Self.cookies, transport: Self.transport())
        let staged = try Self.staged()
        defer { try? FileManager.default.removeItem(at: staged.file) }
        await #expect(throws: ChatError.self) {
            _ = try await backend.uploadAttachment(staged, to: .init("space/s-1")) { _ in }
        }
    }

    @Test func anAnswerWithNoTokenIsADecodingError() async throws {
        var empty = Self.serverMetadata()
        empty.attachmentToken = ""
        let backend = try LocalBridgeBackend(cookies: Self.cookies, transport: Self.transport(empty))
        try await backend.connect()
        let staged = try Self.staged()
        defer { try? FileManager.default.removeItem(at: staged.file) }
        await #expect(throws: ChatError.decoding("the upload finished, but its answer named no attachment")) {
            _ = try await backend.uploadAttachment(staged, to: .init("space/s-1")) { _ in }
        }
    }
}
