import Foundation
import Testing
@testable import GChatBridgeCore

struct MeetPushBootstrapTests {
    private let fields: [String: Any] = [
        "qwAQke": "DynamiteWebUi", "wU9aJb": "key-secret", "pZ68sc": "project-secret",
        "ttqQxf": "topic-secret"
    ]

    private func shell(_ fields: [String: Any]) throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: fields)
        return Data("<script>window.WIZ_global_data=\(String(decoding: data, as: UTF8.self));</script>".utf8)
    }

    @Test(arguments: ["1", "1.0", " 1 ", "1e0"])
    func numericStringProductionSelectorsMatchTheWebReader(_ selector: String) throws {
        let data = try shell(fields.merging(["TyXQle": selector]) { _, new in new })
        let wiz = try #require(WizGlobalData(html: String(decoding: data, as: UTF8.self)))
        #expect(wiz.meetPushConfiguration != nil)
        #expect(wiz.meetPushDiagnostics.last == "Meet watch environment: production")
        #expect(!wiz.meetPushDiagnostics.joined().contains("secret"))
    }

    @Test func onlyKnownProductionSelectorsAreAccepted() throws {
        let rejected: [Any] = ["2", "0", "other-secret", "", true, 2, 0, [1]]
        for value in rejected {
            let data = try shell(fields.merging(["TyXQle": value]) { _, new in new })
            let wiz = try #require(WizGlobalData(html: String(decoding: data, as: UTF8.self)))
            #expect(wiz.meetPushConfiguration == nil)
            #expect(!wiz.meetPushDiagnostics.joined().contains("secret"))
        }
        for value in [NSNumber(value: 1), NSNull()] {
            let data = try shell(fields.merging(["TyXQle": value]) { _, new in new })
            #expect(WizGlobalData(html: String(decoding: data, as: UTF8.self))?.meetPushConfiguration != nil)
        }
    }

    @Test func diagnosticsDistinguishMissingEmptyAndWrongTypeWithoutValues() throws {
        let fields: [String: Any] = ["qwAQke": "DynamiteWebUi", "pZ68sc": "", "ttqQxf": ["private-secret"]]
        let wiz = try #require(WizGlobalData(html: String(decoding: shell(fields), as: UTF8.self)))
        #expect(wiz.meetPushDiagnostics == [
            "Meet watch config wU9aJb: absent", "Meet watch config pZ68sc: string, 0 bytes, invalid",
            "Meet watch config ttqQxf: not a string", "Meet watch environment: production"
        ])
    }

    @Test func standaloneFetchPreservesAccountAndCookieScopeAndAbsorbsRotation() async throws {
        let transport = try FakeHTTPTransport(responses: [HTTPResponse(
            status: 200, headers: HTTPHeaders([("Set-Cookie", "SID=new; Path=/; Secure")]),
            body: shell(fields)
        )])
        let credentials = try SessionCredentials(#require(SessionCookies(cookies: [
            .init(name: "SID", value: "old", domain: ".google.com", path: "/"),
            .init(name: "PRIVATE", value: "meet-only", domain: "meet.google.com", path: "/")
        ])))
        let wiz = try await MeetPushBootstrap(transport: transport, credentials: credentials)
            .load(endpoints: ChatEndpoints(account: .index(2)))
        #expect(wiz.meetPushConfiguration != nil)
        let request = try #require(await transport.sent.first)
        #expect(request.url.absoluteString == "https://chat.google.com/u/2/app/home")
        #expect(request.method == .get)
        #expect(request.headers["Cookie"] == "SID=old")
        #expect(!request.followsRedirects)
        #expect(request.maxBodyBytes == 3_000_000)
        #expect(await credentials.snapshot?.header(for: request.url)?.contains("SID=new") == true)
    }

    @Test func redirectedSignedOutAndMalformedShellsStopWithFixedErrors() async throws {
        let cases: [(HTTPResponse, MeetPushBootstrapError)] = try [
            (
                .init(
                    status: 302,
                    headers: HTTPHeaders([("Location", "https://evil.example/?secret=value")]),
                    body: Data()
                ),
                .redirected(302)
            ),
            (
                .init(status: 403, headers: HTTPHeaders([]), body: Data("private-secret".utf8)),
                .httpStatus(403)
            ),
            (.init(status: 200, headers: HTTPHeaders([]), body: Data("private-secret".utf8)), .invalidShell),
            (.init(status: 200, headers: HTTPHeaders([]), body: shell(fields.merging([
                "qwAQke": "AccountsSignInUi"
            ]) { _, new in new })), .signedOut)
        ]
        for (response, error) in cases {
            let transport = FakeHTTPTransport(responses: [response])
            let credentials = try SessionCredentials(#require(SessionCookies(header: "SID=cookie-secret")))
            await #expect(throws: error) {
                try await MeetPushBootstrap(transport: transport, credentials: credentials)
                    .load(endpoints: ChatEndpoints())
            }
            #expect(await transport.sent.count == 1)
            #expect(!String(describing: error).contains("secret"))
        }
    }
}
