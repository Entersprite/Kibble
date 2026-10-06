import Foundation
import Testing
@testable import GChatBridgeCore

/// The directory search Chat on the web uses for `@` (`findings.md` §56.4,
/// §57): `ListAutocompletions` on `people-pa`, keyed with the Punctual key and
/// signed with a `SAPISIDHASH`. Every cookie value here is invented.
struct PeopleRequestsTests {
    private let cookies = [
        SessionCookies.Cookie(name: "SAPISID", value: "sap-1", domain: ".google.com", path: "/"),
        SessionCookies.Cookie(name: "__Secure-1PAPISID", value: "one-p", domain: ".google.com", path: "/"),
        SessionCookies.Cookie(name: "__Secure-3PAPISID", value: "three-p", domain: ".google.com", path: "/"),
        // Same name, a host the people service never sees: must not be chosen.
        SessionCookies.Cookie(name: "SAPISID", value: "elsewhere", domain: "accounts.example.com", path: "/")
    ]

    /// Records what was hashed and answers with a tag, so a test reads the
    /// exact input string without needing SHA-1 here.
    private func fakeSHA1(_ input: String) -> String {
        "h(\(input))"
    }

    private func input(_ jar: [SessionCookies.Cookie], at timestamp: Int) -> SAPISIDHash.Input {
        SAPISIDHash.Input(
            cookies: jar, url: PeopleRequests.listAutocompletionsURL,
            origin: "https://chat.google.com", timestamp: timestamp
        )
    }

    @Test func sapisidOnlyHashesTimestampCookieAndOrigin() throws {
        let header = try #require(SAPISIDHash.authorization(
            .sapisidOnly,
            for: input(cookies, at: 1_700_000_000),
            sha1: fakeSHA1
        ))
        #expect(header == "SAPISIDHASH 1700000000_h(1700000000 sap-1 https://chat.google.com)")
    }

    @Test func firstAndThirdPartyEachHashTheirOwnCookie() throws {
        let header = try #require(SAPISIDHash.authorization(
            .firstAndThirdParty,
            for: input(cookies, at: 1_700_000_000),
            sha1: fakeSHA1
        ))
        #expect(header == "SAPISIDHASH 1700000000_h(1700000000 sap-1 https://chat.google.com) "
            + "SAPISID1PHASH 1700000000_h(1700000000 one-p https://chat.google.com) "
            + "SAPISID3PHASH 1700000000_h(1700000000 three-p https://chat.google.com)")
    }

    @Test func sameHashThriceRepeatsTheSAPISIDHash() throws {
        let header = try #require(SAPISIDHash.authorization(
            .sameHashThrice,
            for: input(cookies, at: 1_700_000_000),
            sha1: fakeSHA1
        ))
        let hash = "1700000000_h(1700000000 sap-1 https://chat.google.com)"
        #expect(header == "SAPISIDHASH \(hash) SAPISID1PHASH \(hash) SAPISID3PHASH \(hash)")
    }

    @Test func noSAPISIDForTheHostIsNoHeader() {
        let only = [SessionCookies.Cookie(
            name: "SAPISID",
            value: "x",
            domain: "accounts.example.com",
            path: "/"
        )]
        #expect(SAPISIDHash.authorization(.sapisidOnly, for: input(only, at: 1), sha1: fakeSHA1) == nil)
    }

    @Test func theRequestIsTheWebClientsShape() throws {
        let request = PeopleRequests.listAutocompletions(
            query: "ja", key: "key-1", authorization: "SAPISIDHASH x", endpoints: ChatEndpoints()
        )
        #expect(request.method == .post)
        #expect(request.url.host == "people-pa.clients6.google.com")
        #expect(request.url.path
            ==
            "/$rpc/google.internal.people.v2.minimal.PeopleApiAutocompleteMinimalService/ListAutocompletions")
        #expect(request.headers.all("Content-Type") == ["application/json+protobuf"])
        #expect(request.headers.all("Origin") == ["https://chat.google.com"])
        #expect(request.headers.all("X-Goog-Api-Key") == ["key-1"])
        #expect(request.headers.all("X-User-Agent") == ["grpc-web-javascript/0.1"])
        #expect(request.headers.all("X-Goog-AuthUser") == ["0"])
        #expect(request.headers.all("Authorization") == ["SAPISIDHASH x"])
        let body = try JSONSerialization.jsonObject(with: #require(request.body)) as? [Any]
        #expect(body?.first as? String == "ja")
        #expect((body?[3] as? [String]) == ["DYNAMITE_WEB"])
        #expect(body?[4] as? Int == 40)
        #expect((body?[8] as? [Any])?.first as? String == "DYNAMITE_WEB")
    }

    @Test func noAuthorizationIsNoHeader() {
        let request = PeopleRequests.listAutocompletions(
            query: "ja", key: "key-1", authorization: nil, endpoints: ChatEndpoints()
        )
        #expect(request.headers.all("Authorization").isEmpty)
    }

    @Test func theOriginIsTheChatHostWithoutTheAccountPath() {
        #expect(PeopleRequests.origin(of: ChatEndpoints()) == "https://chat.google.com")
    }
}
