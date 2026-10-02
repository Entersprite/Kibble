import Foundation
import Testing
@testable import GChatBridgeCore

/// `RequestStyle.chatHostOnly`: cookies a browser keeps for the chat host
/// alone, withheld from every other host. The jar has no domains, so it sends
/// `COMPASS` and `OSID` to `chat.usercontent.google.com`, which no browser
/// does (`findings.md` §52.8).
@Suite("Attachment fetch: chat-host-only cookies")
struct AttachmentFetchWithholdTests {
    static func credentials() -> SessionCredentials {
        SessionCredentials(SessionCookies(cookies: [
            SessionCookies.Cookie(name: "SID", value: "lowercasesid"),
            SessionCookies.Cookie(name: "COMPASS", value: "lowercasecompass"),
            SessionCookies.Cookie(name: "HSID", value: "lowercasehsid")
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

    @Test("the chat host gets the whole jar, a sibling gets the rest, googleusercontent nothing")
    func withheldFromSiblingsOnly() async throws {
        let sent = try await Self.cookies(AttachmentFetch.RequestStyle(chatHostOnly: ["COMPASS"]))
        #expect(sent == [
            "SID=lowercasesid; COMPASS=lowercasecompass; HSID=lowercasehsid",
            "SID=lowercasesid; HSID=lowercasehsid",
            nil
        ])
    }

    @Test("the app's style withholds nothing")
    func appStyleSendsTheJar() async throws {
        let sent = try await Self.cookies(.app)
        #expect(sent[1] == "SID=lowercasesid; COMPASS=lowercasecompass; HSID=lowercasehsid")
    }
}
