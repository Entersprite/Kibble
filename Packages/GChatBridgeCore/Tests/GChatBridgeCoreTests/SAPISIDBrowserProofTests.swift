import Foundation
import Testing
@testable import GChatBridgeCore

struct SAPISIDBrowserProofTests {
    private func proof(_ cookies: [SessionCookies.Cookie]) -> String? {
        SAPISIDHash.browserAuthorization(for: .init(
            cookies: cookies, url: URL(string: "https://meet.google.com/$rpc/example")!,
            origin: "https://meet.google.com", timestamp: 1000
        ), sha1: { "h(\($0))" })
    }

    @Test func browserSignsEachAvailableCookie() {
        let cookies: [SessionCookies.Cookie] = [
            .init(name: "SAPISID", value: "wrong-host", domain: "chat.google.com", path: "/"),
            .init(name: "SAPISID", value: "primary", domain: ".google.com", path: "/"),
            .init(name: "__Secure-1PAPISID", value: "first", domain: ".google.com", path: "/"),
            .init(name: "__Secure-3PAPISID", value: "third", domain: ".google.com", path: "/")
        ]
        #expect(proof(cookies) == "SAPISIDHASH 1000_h(1000 primary https://meet.google.com) "
            + "SAPISID1PHASH 1000_h(1000 first https://meet.google.com) "
            + "SAPISID3PHASH 1000_h(1000 third https://meet.google.com)")
    }

    @Test func thirdPartyCookieCanSupplyThePrimaryProof() {
        #expect(proof([
            .init(name: "__Secure-3PAPISID", value: "third", domain: ".google.com", path: "/")
        ]) == "SAPISIDHASH 1000_h(1000 third https://meet.google.com) "
            + "SAPISID3PHASH 1000_h(1000 third https://meet.google.com)")
    }

    @Test func absentOptionalCookiesDoNotPreventThePrimaryProof() {
        #expect(proof([
            .init(name: "SAPISID", value: "primary", domain: ".google.com", path: "/")
        ]) == "SAPISIDHASH 1000_h(1000 primary https://meet.google.com)")
        #expect(proof([
            .init(name: "SAPISID", value: "wrong-host", domain: "chat.google.com", path: "/")
        ]) == nil)
        #expect(proof([.init(name: "SAPISID", value: "unscoped-legacy")]) == nil)
    }
}
