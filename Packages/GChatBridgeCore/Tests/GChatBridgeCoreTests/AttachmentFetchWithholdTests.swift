import Foundation
import Testing
@testable import GChatBridgeCore

/// `RequestStyle.chatHostOnly`: an explicit withholding for a probe
/// experimenting with a cookie that would otherwise reach a sibling under
/// domain scoping (`findings.md` §52.9). A cookie such as `COMPASS`, whose own
/// `Domain` already confines it to the chat host, never reaches
/// `chat.usercontent.google.com` regardless of this mechanism
/// (`findings.md` §52.8).
@Suite("Attachment fetch: chat-host-only cookies")
struct AttachmentFetchWithholdTests {
    static func credentials() -> SessionCredentials {
        SessionCredentials(SessionCookies(cookies: [
            SessionCookies.Cookie(name: "SID", value: "lowercasesid", domain: ".google.com", path: "/"),
            SessionCookies.Cookie(
                name: "COMPASS",
                value: "lowercasecompass",
                domain: "chat.google.com",
                path: "/"
            ),
            SessionCookies.Cookie(name: "HSID", value: "lowercasehsid", domain: ".google.com", path: "/")
        ])!)
    }

    static func cookies(_ style: AttachmentFetch.RequestStyle) async throws -> [String?] {
        let transport = FakeHTTPTransport(responses: [
            AttachmentFetchTests.redirect(to: "https://chat.usercontent.google.com/download"),
            AttachmentFetchTests.redirect(to: AttachmentFetchTests.fife),
            AttachmentFetchTests.image("PDF", contentType: "application/pdf")
        ])
        _ = try await AttachmentFetchTests.fetch(transport, credentials: credentials()).fetch(
            token: "t", contentType: "application/pdf", variant: .file, style: style
        )
        return await transport.sent.map { $0.headers["Cookie"] }
    }

    /// Review fix round 1, Important 2: `COMPASS` is host-only and domain
    /// scoping already keeps it off the sibling regardless of
    /// `chatHostOnly`, so withholding it here could never fail. `HSID`
    /// carries `Domain=.google.com` and so is eligible for the sibling under
    /// domain scoping alone - withholding it is the only way this mechanism,
    /// rather than domain scoping, is what is under test.
    @Test("the chat host gets the whole jar, a sibling gets the rest, googleusercontent nothing")
    func withheldFromSiblingsOnly() async throws {
        let sent = try await Self.cookies(AttachmentFetch.RequestStyle(chatHostOnly: ["HSID"]))
        #expect(sent == [
            "SID=lowercasesid; COMPASS=lowercasecompass; HSID=lowercasehsid",
            "SID=lowercasesid",
            nil
        ])
    }

    @Test("the app's style withholds nothing beyond what each cookie's own domain already excludes")
    func appStyleSendsTheJar() async throws {
        let sent = try await Self.cookies(.app)
        // COMPASS never reaches the sibling because its own Domain confines
        // it to the chat host (`findings.md` §52.9) - not because `.app`
        // withholds it; `.app`'s own `chatHostOnly` is empty.
        #expect(sent[1] == "SID=lowercasesid; HSID=lowercasehsid")
    }
}
