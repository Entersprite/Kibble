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
    [[null,"1"],[2,"999999999999999999999"],[["999999999999999999999"],3]]],\#
    [[[null,"1"],[2,"123456789012345678901"],\#
    [["123456789012345678901"],[[1,"1","x"],null,"1759800000000000"]]],\#
    [[null,"1"],[2,"123456789012345678902"],[["123456789012345678902"],[]]]]]
    """#.utf8)

    private static let people = CalendarProbePeople(
        me: .init(id: "self-id", email: "me@example.invalid", label: "self"),
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
            "presence unlisted (id): 3",
            "custom status person 1 (id): set",
            "custom status person 2 (id): none"
        ])
    }

    // MARK: - The section, end to end

    /// Built at run time, so no literal in this file looks like a Google API
    /// key to a secret scanner. Lowercase and mixed, which the shape printer
    /// would mask anyway: the sentinel is for every other line.
    private static let bundleKey = "AI" + "za" + "secretkey" + String(repeating: "q", count: 26)

    private static func response(_ status: Int, _ body: String) -> Result<HTTPResponse, any Error> {
        .success(HTTPResponse(status: status, headers: HTTPHeaders([]), body: Data(body.utf8)))
    }

    private static func credentials() throws -> SessionCredentials {
        let cookies = ["SAPISID", "__Secure-1PAPISID", "__Secure-3PAPISID"].map { name in
            SessionCookies.Cookie(name: name, value: "cookie-secret", domain: ".google.com", path: "/")
        }
        return try SessionCredentials(#require(SessionCookies(cookies: cookies)))
    }

    private static let page = #"<script src="/_/scs/mss-static/_/js/k=boq-dynamite.T.O/d=1/m=_b"></script>"#

    @Test func aRefusedTzliqFallsBackToTheBundlesKeyAndThenAsksEveryVariant() async throws {
        let module = #"x=[1,[true,135],false,[null,null,"\#(String(repeating: "d", count: 39))","#
            + #""\#(Self.bundleKey)"]];"#
        let answer = String(decoding: Self.answer, as: UTF8.self)
        let transport = ScriptedTransport([
            Self.response(401, #"[401,"Request is missing required authentication credential."]"#),
            Self.response(403, #"[403,"The caller does not have permission"]"#),
            Self.response(403, #"[403,"The caller does not have permission"]"#),
            Self.response(200, module),
            Self.response(200, answer),
            Self.response(200, answer), Self.response(200, answer), Self.response(200, answer),
            Self.response(200, answer), Self.response(200, answer)
        ])
        var lines: [String] = []
        let credentials = try Self.credentials()
        let section = PeopleProbeReport.CalendarSection(
            people: Self.people, tzliq: "tzliq-value", page: Self.page, credentials: credentials,
            transport: transport, endpoints: ChatEndpoints(), now: Self.now
        )
        await PeopleProbeReport.appendCalendarStatus(section, lines: &lines, flush: { _ in })
        let sent = await transport.sent
        let text = lines.joined(separator: "\n")

        try #require(sent.count == 10)
        #expect(sent[0].headers.all("Authorization").isEmpty)
        #expect(sent[0].headers.all("X-Goog-Api-Key") == ["tzliq-value"])
        #expect(sent[3].url
            .absoluteString ==
            "https://chat.google.com/_/scs/mss-static/_/js/k=boq-dynamite.T.O/d=1/m=F41ord")
        #expect(sent[3].headers.all("Cookie").isEmpty)
        #expect(sent[4].headers.all("X-Goog-Api-Key") == [Self.bundleKey])
        #expect(sent[4].headers.all("Authorization").first?.hasPrefix("SAPISIDHASH ") == true)
        // Every request after the winner keeps its key and signature.
        #expect(sent[5...].allSatisfy { $0.headers.all("X-Goog-Api-Key") == [Self.bundleKey] })
        #expect(sent[5...]
            .allSatisfy { $0.headers.all("Authorization") == sent[4].headers.all("Authorization") })

        #expect(text.contains("rung Tzliq (11 chars), control without Authorization: status 401"))
        #expect(text.contains("bundle: module F41ord, status 200"))
        #expect(text.contains("1 key literal, config literal yes"))
        #expect(text.contains("rung bundle key 1 (39 chars), sapisidOnly: status 200"))
        #expect(text.contains("calendar self (email): ok, 3 intervals [5 2 3]"))
        for secret in [
            Self.bundleKey,
            "tzliq-value",
            "cookie-secret",
            "me@example",
            "first@example",
            "123456789012345678901",
            "Area/Some_City"
        ] {
            #expect(!text.contains(secret), "printed \(secret)")
        }
    }

    @Test func anAcceptedTzliqNeverFetchesTheBundle() async throws {
        let answer = String(decoding: Self.answer, as: UTF8.self)
        let transport = ScriptedTransport([
            Self.response(401, #"[401,"Request is missing required authentication credential."]"#),
            Self.response(200, answer),
            Self.response(200, answer), Self.response(200, answer), Self.response(200, answer),
            Self.response(200, answer), Self.response(200, answer)
        ])
        var lines: [String] = []
        let credentials = try Self.credentials()
        let section = PeopleProbeReport.CalendarSection(
            people: Self.people, tzliq: "tzliq-value", page: Self.page, credentials: credentials,
            transport: transport, endpoints: ChatEndpoints(), now: Self.now
        )
        await PeopleProbeReport.appendCalendarStatus(section, lines: &lines, flush: { _ in })
        let sent = await transport.sent
        try #require(sent.count == 7)
        #expect(!sent.contains { $0.url.path.contains("/_/js/") })
        #expect(sent.allSatisfy { $0.headers.all("X-Goog-Api-Key") == ["tzliq-value"] })
    }
}
