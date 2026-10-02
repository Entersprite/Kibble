import Foundation
import Testing
@testable import GChatBridgeCore

@Suite("SessionCredentials")
struct SessionCredentialsTests {
    private func cookies(_ pairs: [(String, String)]) -> SessionCookies {
        SessionCookies(cookies: pairs.map { SessionCookies.Cookie(name: $0.0, value: $0.1) })!
    }

    static let chat = URL(string: "https://chat.google.com/")!

    @Test func theHeaderIsTheCurrentJarNotTheCapturedSnapshot() async {
        let credentials = SessionCredentials(cookies([("SIDCC", "old"), ("HSID", "keep")]))
        await credentials.absorb(HTTPHeaders([("Set-Cookie", "SIDCC=new; Path=/; Secure")]), from: Self.chat)
        #expect(await credentials.header() == "SIDCC=new; HSID=keep")
    }

    @Test func rotationIsReportedOnceWhenSomethingActuallyChanges() async {
        let box = RotationBox()
        let credentials = SessionCredentials(cookies([("SIDCC", "old")])) { snapshot in
            await box.record(snapshot)
        }
        await credentials.absorb(HTTPHeaders([("Set-Cookie", "SIDCC=new")]), from: Self.chat)
        #expect(await box.count == 1)
    }

    @Test func resendingAnIdenticalValueIsNotARotation() async {
        let box = RotationBox()
        let credentials = SessionCredentials(cookies([("SIDCC", "same")])) { snapshot in
            await box.record(snapshot)
        }
        await credentials.absorb(HTTPHeaders([("Set-Cookie", "SIDCC=same")]), from: Self.chat)
        // The credential store is on disk. Rewriting an unchanged session once
        // per poll cycle is a write per second, forever.
        // `count` is a rotation tally (an Int), not a collection - `isEmpty`
        // does not apply.
        // swiftlint:disable:next empty_count
        #expect(await box.count == 0)
    }

    @Test func severalCookiesRotatingInOneResponseAreAllAbsorbed() async {
        let credentials = SessionCredentials(
            cookies([("SIDCC", "a"), ("__Secure-1PSIDCC", "b"), ("__Secure-3PSIDCC", "c")])
        )
        await credentials.absorb(HTTPHeaders([
            ("Set-Cookie", "SIDCC=a2"),
            ("Set-Cookie", "__Secure-1PSIDCC=b2"),
            ("Set-Cookie", "__Secure-3PSIDCC=c2")
        ]), from: Self.chat)
        #expect(await credentials.rotationCount() == 3)
    }

    /// The controller ruling that moved `authorised(_:)` off `ChannelSession`
    /// and onto the credential itself: the header it puts on a request must be
    /// the rotated value, not the one the credential was constructed with.
    @Test func authorisingUsesTheRotatedValueNotTheCapturedOne() async throws {
        let credentials = SessionCredentials(cookies([("SIDCC", "old")]))
        await credentials.absorb(HTTPHeaders([("Set-Cookie", "SIDCC=new")]), from: Self.chat)
        let request = try HTTPRequest(url: #require(URL(string: "https://chat.google.com/")))
        let authorising = await credentials.authorising(request)
        #expect(authorising.headers["Cookie"] == "SIDCC=new")
    }

    // MARK: - Scoped per request (findings.md §52.9)

    static func scoped() -> SessionCredentials {
        SessionCredentials(SessionCookies(cookies: [
            SessionCookies.Cookie(name: "SID", value: "lowercasesid", domain: ".google.com", path: "/"),
            SessionCookies.Cookie(name: "SIDCC", value: "one", domain: ".google.com", path: "/"),
            SessionCookies.Cookie(
                name: "COMPASS",
                value: "lowercasecompass",
                domain: "chat.google.com",
                path: "/"
            )
        ])!)
    }

    static func request(_ url: String) -> HTTPRequest {
        HTTPRequest(url: URL(string: url)!)
    }

    /// The §52.9 regression: this is the request that was refused for nine
    /// probe runs. It fails if `authorising` goes back to the flat jar.
    @Test("the download host gets the .google.com cookies and not chat.google.com's")
    func downloadHostIsScoped() async {
        let sent = await Self.scoped()
            .authorising(Self.request("https://chat.usercontent.google.com/download"))
        #expect(sent.headers["Cookie"] == "SID=lowercasesid; SIDCC=one")
    }

    @Test("a host no cookie admits gets no Cookie header at all")
    func noHeaderWhenNothingAdmits() async {
        let sent = await Self.scoped().authorising(Self.request("https://lh3.googleusercontent.com/fife/x"))
        #expect(sent.headers.all("Cookie").isEmpty)
    }

    @Test("a session stored before domains were kept still sends everything to chat.google.com")
    func legacySessionStillWorksForChat() async throws {
        let legacy = try SessionCredentials(#require(SessionCookies(header: "SID=a; COMPASS=b; OSID=c")))
        let chat = await legacy.authorising(Self.request("https://chat.google.com/u/0/webchannel/events"))
        let download = await legacy.authorising(Self.request("https://chat.usercontent.google.com/download"))
        #expect(chat.headers["Cookie"] == "SID=a; COMPASS=b; OSID=c")
        #expect(download.headers.all("Cookie").isEmpty)
    }

    @Test("a sibling host's rotation of a .google.com cookie reaches the chat host's next request")
    func siblingRotationReachesChat() async throws {
        let credentials = Self.scoped()
        let download = try #require(URL(string: "https://chat.usercontent.google.com/download"))
        await credentials.absorb(
            HTTPHeaders([("Set-Cookie", "SIDCC=two; Domain=.google.com; Path=/")]),
            from: download
        )
        let next = await credentials.authorising(Self.request("https://chat.google.com/u/0/api/x"))
        #expect(next.headers["Cookie"] == "SID=lowercasesid; SIDCC=two; COMPASS=lowercasecompass")
    }

    @Test("withholding names leaves them out of this one request")
    func withholding() async {
        let sent = await Self.scoped().authorising(
            Self.request("https://chat.google.com/"),
            withholding: ["COMPASS"]
        )
        #expect(sent.headers["Cookie"] == "SID=lowercasesid; SIDCC=one")
    }
}

/// An actor rather than a captured `var`, because the callback is `@Sendable`
/// and crosses an isolation boundary.
actor RotationBox {
    private(set) var count = 0
    private(set) var last: SessionCookies?

    func record(_ snapshot: SessionCookies) {
        count += 1
        last = snapshot
    }
}
