import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// Answers the connect sequence with a signed-in shell, and any `.png` with
/// a tiny image; records every request.
private actor ImageTransport: HTTPTransport {
    struct NoStream: Error {}
    private(set) var sent: [HTTPRequest] = []

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        sent.append(request)
        if request.url.path.contains("/mole/world") {
            let html = LocalBridgeBackendTests.shell(app: "DynamiteWebUi")
            return HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data(html.utf8))
        }
        if request.url.path.hasSuffix(".png") {
            return HTTPResponse(
                status: 200, headers: HTTPHeaders([("Content-Type", "image/png")]), body: Data([0x89, 0x50])
            )
        }
        return HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data())
    }

    func stream(_: HTTPRequest) async throws -> HTTPStream {
        throw NoStream()
    }
}

/// `LocalBridgeBackend.remoteImage(_:)` (links spec §4.4).
@Suite(.timeLimit(.minutes(1)))
struct RemoteImageBackendTests {
    /// Lowercase on purpose (CLAUDE.md, the leak-test rule).
    private static let cookies = SessionCookies(header: "SID=lowercasecookiesecret; COMPASS=b; OSID=c")!

    @Test func theCapabilityIsAdvertised() {
        let backend = LocalBridgeBackend(cookies: Self.cookies, transport: ImageTransport())
        #expect(backend.capabilities.canFetchRemoteImages)
    }

    /// The sentinel: an image on the chat host itself, where `AttachmentFetch`'s
    /// per-host rule *would* send the session. This fetch must not.
    @Test func noHopCarriesTheSessionEvenToTheChatHost() async throws {
        let transport = ImageTransport()
        let backend = LocalBridgeBackend(cookies: Self.cookies, transport: transport)
        try await backend.connect()
        _ = try await backend.remoteImage(#require(URL(string: "https://chat.google.com/preview/x.png")))
        let sent = await transport.sent
        let image = try #require(sent.first { $0.url.path.hasSuffix(".png") })
        #expect(image.headers["Cookie"] == nil)
        #expect(!image.headers.fields.contains { $0.value.contains("lowercasecookiesecret") })
    }

    @Test func noSessionIsNeeded() async throws {
        let backend = LocalBridgeBackend(cookies: Self.cookies, transport: ImageTransport())
        #expect(try await !backend.remoteImage(#require(URL(string: "https://acme.example/x.png")))
            .isEmpty)
    }

    @Test func aFailureNamesNoURL() async throws {
        let backend = LocalBridgeBackend(cookies: Self.cookies, transport: ImageTransport())
        do {
            _ = try await backend
                .remoteImage(#require(URL(string: "http://secret-intranet.example/x.png")))
            Issue.record("expected a refusal")
        } catch {
            #expect(!String(describing: error).contains("secret-intranet"))
        }
    }
}
