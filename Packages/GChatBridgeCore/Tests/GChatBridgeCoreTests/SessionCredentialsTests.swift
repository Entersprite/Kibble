import Foundation
import Testing
@testable import GChatBridgeCore

@Suite("SessionCredentials")
struct SessionCredentialsTests {
    private func cookies(_ pairs: [(String, String)]) -> SessionCookies {
        SessionCookies(cookies: pairs.map { SessionCookies.Cookie(name: $0.0, value: $0.1) })!
    }

    @Test func theHeaderIsTheCurrentJarNotTheCapturedSnapshot() async {
        let credentials = SessionCredentials(cookies([("SIDCC", "old"), ("HSID", "keep")]))
        await credentials.absorb(HTTPHeaders([("Set-Cookie", "SIDCC=new; Path=/; Secure")]))
        #expect(await credentials.header() == "SIDCC=new; HSID=keep")
    }

    @Test func rotationIsReportedOnceWhenSomethingActuallyChanges() async {
        let box = RotationBox()
        let credentials = SessionCredentials(cookies([("SIDCC", "old")])) { snapshot in
            await box.record(snapshot)
        }
        await credentials.absorb(HTTPHeaders([("Set-Cookie", "SIDCC=new")]))
        #expect(await box.count == 1)
    }

    @Test func resendingAnIdenticalValueIsNotARotation() async {
        let box = RotationBox()
        let credentials = SessionCredentials(cookies([("SIDCC", "same")])) { snapshot in
            await box.record(snapshot)
        }
        await credentials.absorb(HTTPHeaders([("Set-Cookie", "SIDCC=same")]))
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
        ]))
        #expect(await credentials.rotationCount() == 3)
    }

    /// The controller ruling that moved `authorised(_:)` off `ChannelSession`
    /// and onto the credential itself: the header it puts on a request must be
    /// the rotated value, not the one the credential was constructed with.
    @Test func authorisingUsesTheRotatedValueNotTheCapturedOne() async throws {
        let credentials = SessionCredentials(cookies([("SIDCC", "old")]))
        await credentials.absorb(HTTPHeaders([("Set-Cookie", "SIDCC=new")]))
        let request = try HTTPRequest(url: #require(URL(string: "https://chat.google.com/")))
        let authorising = await credentials.authorising(request)
        #expect(authorising.headers["Cookie"] == "SIDCC=new")
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
