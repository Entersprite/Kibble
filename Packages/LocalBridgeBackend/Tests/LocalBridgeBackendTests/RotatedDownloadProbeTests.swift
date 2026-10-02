import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// A download host that serves only a request carrying `__Secure-1PSIDTS`,
/// which is the hypothesis `findings.md` §52.7 leaves open, and an accounts
/// host that sets it.
private actor PSIDTSTransport: HTTPTransport {
    struct NoStream: Error {}

    private(set) var sent: [HTTPRequest] = []

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        sent.append(request)
        if request.url.host() == "accounts.google.com" {
            return HTTPResponse(status: 200, headers: HTTPHeaders([
                ("Set-Cookie", "__Secure-1PSIDTS=lowercasenewvalue; Domain=.google.com; Secure; HttpOnly"),
                ("Set-Cookie", "SIDCC=lowercasenewvalue; Domain=.google.com")
            ]), body: Data())
        }
        if request.url.path.contains("/api/get_attachment_url") {
            return HTTPResponse(status: 302, headers: HTTPHeaders([
                ("Location", "https://chat.usercontent.google.com/download?attachment_token=x&authuser=0")
            ]), body: Data())
        }
        let cookie = request.headers["Cookie"] ?? ""
        return cookie.contains("__Secure-1PSIDTS=")
            ? HTTPResponse(
                status: 200,
                headers: HTTPHeaders([("Content-Type", "application/pdf")]),
                body: Data("PDF".utf8)
            )
            : HTTPResponse(status: 403, headers: HTTPHeaders([]), body: Data())
    }

    func stream(_: HTTPRequest) async throws -> HTTPStream {
        throw NoStream()
    }
}

private actor RotationCount {
    private(set) var value = 0
    func increment() {
        value += 1
    }
}

struct RotatedDownloadProbeTests {
    static let upload = ProbedUpload(token: "lowercasetoken", contentType: "application/pdf")

    @Test("the rung rotates a copy, downloads with it, and leaves the session it copied alone")
    func rotatesACopy() async throws {
        let transport = PSIDTSTransport()
        let saved = RotationCount()
        let session = try SessionCredentials(
            #require(SessionCookies(cookies: [SessionCookies.Cookie(
                name: "SID",
                value: "lowercasesid"
            )])),
            onRotation: { _ in await saved.increment() }
        )
        var lines: [String] = []
        await APIProbeReport.appendRotatedDownloadSection(
            upload: Self.upload,
            rung: APIProbeReport.RotationRung(
                transport: transport, endpoints: ChatEndpoints(), credentials: session, xsrfToken: "x"
            ),
            lines: &lines
        )
        #expect(lines.prefix(4) == [
            "attachment download after RotateCookies (a throwaway copy of the session; nothing is saved):",
            "  RotateCookies: 200, set __Secure-1PSIDTS,SIDCC",
            "  copy now holds: __Secure-1PSIDTS yes, __Secure-3PSIDTS no",
            "  5 app request, rotated copy: chat.google.com 302 (credentials)"
                + " → chat.usercontent.google.com 200 (credentials)"
        ])
        #expect(!lines.joined().contains("lowercase"))
        // The session the rung copied: never rotated, never saved.
        #expect(await session.snapshot?["__Secure-1PSIDTS"] == nil)
        #expect(await saved.value == 0)
    }

    @Test("no file upload, no requests")
    func noUploadNoRequests() async throws {
        let transport = PSIDTSTransport()
        var lines: [String] = []
        try await APIProbeReport.appendRotatedDownloadSection(
            upload: nil,
            rung: APIProbeReport.RotationRung(
                transport: transport,
                endpoints: ChatEndpoints(),
                credentials: SessionCredentials(#require(SessionCookies(cookies: [.init(
                    name: "SID",
                    value: "v"
                )]))),
                xsrfToken: nil
            ),
            lines: &lines
        )
        #expect(await transport.sent.isEmpty)
        #expect(lines.count == 2)
    }

    @Test(arguments: [("__Secure-1PSIDTS", "__Secure-1PSIDTS"), ("we ird=", "c7")])
    func aCookieNamePrintsOnlyWhenItIsPlain(_ name: String, _ printed: String) {
        #expect(APIProbeReport.cookieNameShape(name) == printed)
    }
}
