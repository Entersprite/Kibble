import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// `--probe=people`'s calendar section: `GetAssistiveFeatures`, the call
/// Chat on the web takes "In a meeting" from (`findings.md` §62). It prints
/// shapes, member numbers and times relative to the run, never a value.
/// Every value here is invented.
struct PeopleProbeCalendarTests {
    /// Inside the fixture's meeting, which runs 1_759_690_000.5 to 1_759_693_600.
    private static let now = Date(timeIntervalSince1970: 1_759_691_000)

    // MARK: - The printer

    @Test func theShapeKeepsSmallNumbersAndTurnsTimesRelative() {
        let body = #"["1759698200",[[[null,"1"],[1,"me@example.invalid"],[[["1759690000",500000000]]]]],"#
            + #"null,150,true,"123456789012345678901",{"k":"v"}]"#
        #expect(PeopleProbeReport.maskedShape(Data(body.utf8), now: Self.now)
            == "[now+2h,[[[null,d1],[1,s18],[[[now-17m,n9]]]]],null,n3,true,d21,{s1:s1}]")
    }

    @Test func somethingThatIsNotJSONIsCountedOnly() {
        #expect(PeopleProbeReport.maskedShape(Data("<html>".utf8), now: Self.now) == "unparsed(6)")
    }

    // MARK: - Whom to ask

    private static let me = ChatKit.Member.ID("self-id")
    private static let first = ChatKit.Member.ID("first-id")
    private static let second = ChatKit.Member.ID("second-id")

    /// Two DMs with `first`, one with `second` more recent than both, and a
    /// space and a group DM, which are not asked about.
    private static let conversations: [Conversation] = {
        func dm(
            _ id: String,
            _ kind: Conversation.Kind,
            _ seconds: TimeInterval,
            _ members: [ChatKit.Member.ID]
        )
            -> Conversation {
            Conversation(
                id: .init(id), kind: kind, lastActivity: Date(timeIntervalSince1970: seconds),
                members: members
            )
        }
        return [
            dm("dm/a", .directMessage, 3, [me, first]),
            dm("dm/b", .directMessage, 5, [second, me]),
            dm("dm/c", .directMessage, 1, [me, first]),
            dm("space/s", .space, 9, [me, .init("x")]),
            dm("dm/g", .groupDirectMessage, 9, [me, .init("y")])
        ]
    }()

    @Test func partnersAreTheMostRecentDMsOthersOnce() {
        let members = [
            ChatKit.Member(id: Self.me, kind: .human, email: "me@example.invalid"),
            ChatKit.Member(id: Self.first, kind: .human, email: "first@example.invalid"),
            ChatKit.Member(id: Self.second, kind: .human)
        ]
        let people = PeopleProbeReport.calendarPeople(
            conversations: Self.conversations, members: members, selfUserID: "self-id", limit: 10
        )
        #expect(people.me == .init(id: "self-id", email: "me@example.invalid", label: "self"))
        #expect(people.partners == [
            .init(id: "second-id", email: nil, label: "person 1"),
            .init(id: "first-id", email: "first@example.invalid", label: "person 2")
        ])
    }

    // MARK: - The summary

    private static let answer = Data(#"""
    ["1759700000",\#
    [[[null,"1"],[1,"ME@example.invalid"],\#
    [[[[["1759690000",500000000],["1759693600"]],[null,null,null,null,\#
    [null,["1759600000"],["1759690000"],["1759693600"],["1759693600"]]],\#
    [null,null,["Area/Some_City"]]],\#
    [[["1759693600"],["1759697200"]],[null,[]],[null,null,["Area/Some_City"]]],\#
    [[["1759697200"],["1759700800",0]],[null,null,[null,["1759700800"]]],\#
    [null,null,["Area/Some_City"]]]],\#
    ["1759777200",0],[[1,540,1020],[2,540,1020]]]],\#
    [[5,"1"],[2,"123456789012345678902"]]],\#
    null,null,\#
    [[[null,"1"],[2,"123456789012345678901"],[["123456789012345678901"],1]],\#
    [[null,"1"],[2,"999999999999999999999"],[["999999999999999999999"],150]]],\#
    [[[null,"1"],[2,"123456789012345678901"],\#
    [["123456789012345678901"],[[1,"1","x"],null,"1759800000000000"]]],\#
    [[null,"1"],[2,"123456789012345678902"],[["123456789012345678902"],[]]]]]
    """#.utf8)

    /// The local user's email in mixed case, as `get_members` may give it:
    /// the wire wants it lowercased (§62.5).
    private static let people = CalendarProbePeople(
        me: .init(id: "self-id", email: "Me@Example.invalid", label: "self"),
        partners: [
            .init(id: "123456789012345678901", email: "first@example.invalid", label: "person 1"),
            .init(id: "123456789012345678902", email: nil, label: "person 2")
        ]
    )

    @Test func eachEntryIsNamedByItsLabelWithItsIntervalsAndTimes() throws {
        let answer = try #require(PeopleStackAnswer(Self.answer))
        #expect(PeopleProbeReport.answerLines(answer, people: Self.people, now: Self.now) == [
            "calendar self (email): ok, 3 intervals [5 2 3], now 5 {f2 now-25h, f3 now-17m, f4 now+43m, "
                + "f5 now+43m}, valid until now+24h, rows 2, context 14 chars",
            "calendar person 2 (id): status 5, no payload",
            "presence person 1 (id): 1",
            "presence unlisted (id): n3",
            "custom status person 1 (id): set",
            "custom status person 2 (id): none"
        ])
    }

    // MARK: - The section, end to end

    /// Built at run time, so no literal in this file looks like a Google API
    /// key to a secret scanner. Both are 39 characters, like the real ones,
    /// and lowercase, which the error printer's sentence check lets through:
    /// only the redaction of long runs stands between them and the report.
    private static let bundleKey = "AI" + "za" + "secretkey" + String(repeating: "q", count: 26)
    private static let tzliq = "tzliqsecret" + String(repeating: "t", count: 28)
    private static let otherKey = "AI" + "za" + "otherkey" + String(repeating: "o", count: 27)

    private static func response(_ status: Int, _ body: String) -> Result<HTTPResponse, any Error> {
        .success(HTTPResponse(status: status, headers: HTTPHeaders([]), body: Data(body.utf8)))
    }

    private static let unauthenticated = response(
        401,
        #"[401,"Request is missing required authentication."]"#
    )
    private static let denied = response(403, #"[403,"The caller does not have permission"]"#)
    private static let answered = response(200, String(decoding: answer, as: UTF8.self))

    /// A refusal that names the consumer, the way Google's do.
    private static func naming(_ key: String) -> Result<HTTPResponse, any Error> {
        response(403, #"[403,"Consumer 'api_key:\#(key)' for 123456789012345678901 is blocked."]"#)
    }

    private static func module(_ keys: [String]) -> Result<HTTPResponse, any Error> {
        let others = keys.dropFirst().map { #"b="\#($0)";"# }.joined()
        return response(
            200,
            #"x=[1,[true,135],false,[null,null,"\#(String(repeating: "d", count: 39))","#
                + #""\#(keys[0])"]];"# + others
        )
    }

    private static func credentials(_ names: [String]) throws -> SessionCredentials {
        let cookies = names.map { name in
            SessionCookies.Cookie(name: name, value: "cookie-secret", domain: ".google.com", path: "/")
        }
        return try SessionCredentials(#require(SessionCookies(cookies: cookies)))
    }

    private static let allThree = ["SAPISID", "__Secure-1PAPISID", "__Secure-3PAPISID"]

    private static let page = #"<script src="/_/scs/mss-static/_/js/k=boq-dynamite.T.O/d=1/m=_b"></script>"#

    private func run(
        _ responses: [Result<HTTPResponse, any Error>],
        tzliq: String = Self.tzliq,
        cookies: [String] = Self.allThree,
        signingTime: @escaping @Sendable () -> Date = { Self.now }
    ) async throws -> (text: String, sent: [HTTPRequest]) {
        let transport = ScriptedTransport(responses)
        var lines: [String] = []
        let section = try PeopleProbeReport.CalendarSection(
            people: Self.people, tzliq: tzliq, page: Self.page, credentials: Self.credentials(cookies),
            transport: transport, endpoints: ChatEndpoints(), now: Self.now,
            // Pinned: a signature carries the second it was made in, so two of
            // one variant differ across a second boundary (session 58).
            signingTime: signingTime
        )
        await PeopleProbeReport.appendCalendarStatus(section, lines: &lines, flush: { _ in })
        return await (lines.joined(separator: "\n"), transport.sent)
    }

    private func key(_ request: HTTPRequest) -> String? {
        request.headers.all("X-Goog-Api-Key").first
    }

    private func signature(_ request: HTTPRequest) -> String? {
        request.headers.all("Authorization").first
    }

    @Test func aRefusedTzliqFallsBackToTheBundlesKeyAndThenAsksEveryVariant() async throws {
        let (text, sent) = try await run([
            Self.unauthenticated, Self.naming(Self.tzliq), Self.denied,
            Self.module([Self.bundleKey]),
            Self.naming(Self.bundleKey), Self.answered,
            Self.answered, Self.answered, Self.answered, Self.answered, Self.answered
        ])
        try #require(sent.count == 11)
        #expect(signature(sent[0]) == nil)
        #expect(key(sent[0]) == Self.tzliq)
        #expect(String(decoding: sent[0].body ?? Data(), as: UTF8.self)
            .contains(#"[1,"me@example.invalid"]"#))
        #expect(sent[3].url.absoluteString
            == "https://chat.google.com/_/scs/mss-static/_/js/k=boq-dynamite.T.O/d=1/m=F41ord")
        #expect(sent[3].headers.all("Cookie").isEmpty)
        #expect(sent[5...].allSatisfy { key($0) == Self.bundleKey })
        let winner = try #require(signature(sent[5]))
        #expect(winner.hasPrefix("SAPISIDHASH ") && winner.contains("SAPISID3PHASH "))
        // Every question after the winner keeps its key and signature.
        #expect(sent[6...].allSatisfy { signature($0) == winner })

        #expect(text.contains("rung Tzliq (39 chars), control without Authorization: status 401"))
        #expect(text.contains("error 403 Consumer 'api_key:<39 chars>' for <21 chars> is blocked."))
        #expect(text.contains("bundle: module F41ord, status 200"))
        #expect(text.contains("1 key literal, config literal yes"))
        #expect(text.contains("rung bundle key 1 (39 chars), firstAndThirdParty: status 200"))
        #expect(text.contains("calendar self (email): ok, 3 intervals [5 2 3]"))
        // A colleague's day is summarised, never printed whole: shapes for self only.
        #expect(text.components(separatedBy: "shape: ").count - 1 == 2)
        let printed = text.lowercased()
        for secret in [
            Self.bundleKey,
            Self.tzliq,
            "cookie-secret",
            "example.invalid",
            "123456789012345678901",
            "area/some_city",
            String(winner.dropFirst("SAPISIDHASH ".count).prefix(30))
        ] {
            #expect(!printed.contains(secret.lowercased()), "printed \(secret)")
        }
    }

    @Test func anAcceptedTzliqNeverFetchesTheBundle() async throws {
        let (_, sent) = try await run([
            Self.unauthenticated, Self.answered,
            Self.answered, Self.answered, Self.answered, Self.answered, Self.answered
        ])
        try #require(sent.count == 7)
        #expect(!sent.contains { $0.url.path.contains("/_/js/") })
        #expect(sent.allSatisfy { key($0) == Self.tzliq })
    }

    /// An unsigned call that is answered is recorded, never chosen: Google
    /// may answer an anonymous caller with "not found" for everyone, and
    /// every later question would then go unsigned.
    @Test func theUnsignedControlNeverWins() async throws {
        let (text, sent) = try await run([
            Self.answered, Self.response(200, "[null]"), Self.answered,
            Self.answered, Self.answered, Self.answered, Self.answered, Self.answered
        ])
        try #require(sent.count == 8)
        #expect(sent[1...].allSatisfy { signature($0) != nil })
        #expect(text.contains("sapisidOnly: status 200, 6 bytes, not an answer, shape [null]"))
        #expect(text.contains("with Tzliq (39 chars), firstAndThirdParty:"))
    }

    /// A signature whose cookie is absent is not sent unsigned under its name.
    @Test func aVariantWhoseCookieIsAbsentIsSkipped() async throws {
        let (text, sent) = try await run([
            Self.unauthenticated, Self.denied,
            Self.module([Self.bundleKey]), Self.answered,
            Self.answered, Self.answered, Self.answered, Self.answered, Self.answered
        ], cookies: ["SAPISID"])
        try #require(sent.count == 9)
        #expect(text
            .contains("rung Tzliq (39 chars), firstAndThirdParty: skipped, a cookie it hashes is absent"))
        #expect(sent.enumerated().allSatisfy { index, request in
            index == 0 || request.url.path.contains("/_/js/") || signature(request) != nil
        })
    }

    @Test func aBundleKeyEqualToTzliqIsNotTriedAgain() async throws {
        let (_, sent) = try await run([
            Self.unauthenticated, Self.denied, Self.denied,
            Self.module([Self.otherKey, Self.bundleKey]), Self.answered,
            Self.answered, Self.answered, Self.answered, Self.answered, Self.answered
        ], tzliq: Self.otherKey)
        try #require(sent.count == 10)
        #expect(key(sent[4]) == Self.bundleKey)
    }
}
