import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// `LocalBridgeBackend.customEmojiImage(_:)`, reached through a real
/// `connect()`. The chain is §54.4's: one 302 from the chat host to `lh3`.
private actor EmojiTransport: HTTPTransport {
    struct NoStream: Error {}

    private let shell: HTTPResponse
    /// The final hop's response, today's PNG by default so every test but
    /// Fix 4's own is unaffected.
    private let lh3Response: HTTPResponse
    private(set) var sent: [HTTPRequest] = []

    init(
        shell: HTTPResponse,
        lh3Response: HTTPResponse = HTTPResponse(
            status: 200, headers: HTTPHeaders([("Content-Type", "image/png")]),
            body: Data([0x89, 0x50, 0x4E, 0x47])
        )
    ) {
        self.shell = shell
        self.lh3Response = lh3Response
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        sent.append(request)
        if request.url.path.contains("/mole/world") {
            return shell
        }
        if request.url.path.contains("/api/get_custom_emoji_image") {
            return HTTPResponse(
                status: 302,
                headers: HTTPHeaders([("Location", "https://lh3.googleusercontent.com/emoji/x")]),
                body: Data()
            )
        }
        if request.url.host() == "lh3.googleusercontent.com" {
            return lh3Response
        }
        return HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data())
    }

    func stream(_: HTTPRequest) async throws -> HTTPStream {
        throw NoStream()
    }
}

@Suite(.timeLimit(.minutes(1)))
struct CustomEmojiImageBackendTests {
    private static let cookies = SessionCookies(header: "SID=lowercasecookiesecret; COMPASS=b; OSID=c")!
    private static let parrot = CustomEmojiRef(
        id: "e-1", shortcode: ":parrot:", imageToken: "lowercasereadtoken"
    )
    private static let tokenless = CustomEmojiRef(id: "e-1", shortcode: ":parrot:")

    private static func transport(lh3Response: HTTPResponse? = nil) -> EmojiTransport {
        let html = LocalBridgeBackendTests.shell(app: "DynamiteWebUi")
        let shell = HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data(html.utf8))
        guard let lh3Response else { return EmojiTransport(shell: shell) }
        return EmojiTransport(shell: shell, lh3Response: lh3Response)
    }

    @Test func theCapabilityIsAdvertised() {
        let backend = LocalBridgeBackend(cookies: Self.cookies, transport: Self.transport())
        #expect(backend.capabilities.canFetchCustomEmoji)
    }

    @Test func theImageComesBackThroughTheRedirect() async throws {
        let transport = Self.transport()
        let backend = LocalBridgeBackend(cookies: Self.cookies, transport: transport)
        try await backend.connect()
        let bytes = try await backend.customEmojiImage(Self.parrot)
        #expect(bytes == Data([0x89, 0x50, 0x4E, 0x47]))
        let sent = await transport.sent
        let call = try #require(sent.first { $0.url.path.contains("/api/get_custom_emoji_image") })
        #expect(call.url.query(percentEncoded: true) == "custom_emoji_read_token=lowercasereadtoken")
        let lh3 = try #require(sent.first { $0.url.host() == "lh3.googleusercontent.com" })
        #expect(!lh3.headers.fields.contains { $0.value.contains("lowercasecookiesecret") })
    }

    /// Review Focus 1: a reference stored before the token was kept sends
    /// nothing, even on a connected session.
    @Test func noTokenThrowsBeforeAnyRequest() async throws {
        let transport = Self.transport()
        let backend = LocalBridgeBackend(cookies: Self.cookies, transport: transport)
        try await backend.connect()
        await #expect(throws: ChatError.self) {
            _ = try await backend.customEmojiImage(Self.tokenless)
        }
        #expect(await transport.sent.allSatisfy { !$0.url.path.contains("/api/get_custom_emoji_image") })
    }

    /// Fix 4: only `text/html` is rejected upstream (`AttachmentFetchFailure`'s
    /// own page guard), so a 200 of any other non-image type needs its own
    /// check - otherwise `AttachmentCache` would write it to disk as the
    /// emoji's picture, for good.
    @Test func aNonImageResponseThrowsRatherThanBeingReturned() async throws {
        let transport = Self.transport(lh3Response: HTTPResponse(
            status: 200,
            headers: HTTPHeaders([("Content-Type", "text/plain")]),
            body: Data("not an image".utf8)
        ))
        let backend = LocalBridgeBackend(cookies: Self.cookies, transport: transport)
        try await backend.connect()
        await #expect(throws: ChatError.self) {
            _ = try await backend.customEmojiImage(Self.parrot)
        }
    }

    @Test func beforeConnectItThrowsRatherThanFetching() async {
        let transport = Self.transport()
        let backend = LocalBridgeBackend(cookies: Self.cookies, transport: transport)
        await #expect(throws: ChatError.self) {
            _ = try await backend.customEmojiImage(Self.parrot)
        }
        #expect(await transport.sent.isEmpty)
    }

    /// Session 38 §4.1: through `any ChatBackend`, the backend's own method
    /// answers, not the refusing default. The refusal would name the
    /// capability; the backend's own guard does not.
    @Test func theImplementationIsReachedThroughTheExistential() async {
        let backend: any ChatBackend = LocalBridgeBackend(cookies: Self.cookies, transport: Self.transport())
        do {
            _ = try await backend.customEmojiImage(Self.tokenless)
            Issue.record("expected a throw")
        } catch {
            #expect(error as? ChatError != ChatError.unsupported(capability: "canFetchCustomEmoji"))
        }
    }
}
