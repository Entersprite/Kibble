import Foundation
import Testing
@testable import GChatBridgeCore

/// `GetAssistiveFeatures` on `peoplestack-pa`, the call Chat on the web takes
/// "In a meeting" from (`findings.md` §62). The shapes are the owner's
/// capture's, read as structure only; every value here is invented.
struct PeopleStackRequestsTests {
    // MARK: - The request

    @Test func theCapturesSelfCalendarRequestIsReproducedExactly() throws {
        let request = PeopleStackRequests.getAssistiveFeatures(
            [.init(keys: [.email("me@example.invalid")], features: [.calendarStatus])],
            client: 3, key: "key-1", authorization: "SAPISIDHASH x", endpoints: ChatEndpoints()
        )
        let body = try String(decoding: #require(request.body), as: UTF8.self)
        #expect(body == #"[[3,"1"],[[[[1,"me@example.invalid"]],[1]]]]"#)
    }

    @Test func peopleAreBatchedPerFeatureByPersonID() throws {
        let people: [PeopleStackRequests.Key] = [
            .personID("123456789012345678901"), .personID("123456789012345678902")
        ]
        let request = PeopleStackRequests.getAssistiveFeatures(
            [.init(keys: people, features: [.presence]), .init(keys: people, features: [.userStatus])],
            client: 1, key: "key-1", authorization: nil, endpoints: ChatEndpoints()
        )
        let body = try String(decoding: #require(request.body), as: UTF8.self)
        #expect(body == #"[[1,"1"],[[[[2,"123456789012345678901"],[2,"123456789012345678902"]],[4]],"#
            + #"[[[2,"123456789012345678901"],[2,"123456789012345678902"]],[5]]]]"#)
    }

    @Test func theRequestCarriesTheWebClientsHeaders() {
        let request = PeopleStackRequests.getAssistiveFeatures(
            [.init(keys: [.personID("1")], features: [.calendarStatus])],
            client: 1, key: "key-1", authorization: "SAPISIDHASH x", endpoints: ChatEndpoints()
        )
        #expect(request.method == .post)
        #expect(request.url.host == "peoplestack-pa.clients6.google.com")
        #expect(request.url.path == "/$rpc/social.people.backend.service.intelligence.proto."
            + "PeopleStackIntelligenceService/GetAssistiveFeatures")
        #expect(request.headers.all("Content-Type") == ["application/json+protobuf"])
        #expect(request.headers.all("X-User-Agent") == ["grpc-web-javascript/0.1"])
        #expect(request.headers.all("X-Goog-Api-Key") == ["key-1"])
        #expect(request.headers.all("Origin") == ["https://chat.google.com"])
        #expect(request.headers.all("X-Goog-AuthUser") == ["0"])
        #expect(request.headers.all("Authorization") == ["SAPISIDHASH x"])
    }

    @Test func noAuthorizationIsNoHeader() {
        let request = PeopleStackRequests.getAssistiveFeatures(
            [.init(keys: [.personID("1")], features: [.calendarStatus])],
            client: 1, key: "key-1", authorization: nil, endpoints: ChatEndpoints()
        )
        #expect(request.headers.all("Authorization").isEmpty)
    }

    // MARK: - The answer

    /// The capture's layout (§62.6) with invented values: a calendar entry
    /// for an email with three intervals, a "not found" calendar entry, two
    /// presence entries and two custom status entries, one of them empty.
    static let answer = #"""
    ["1759700000",\#
    [[[null,"1"],[1,"me@example.invalid"],\#
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
    [[null,"1"],[2,"123456789012345678902"],[["123456789012345678902"],3]]],\#
    [[[null,"1"],[2,"123456789012345678901"],\#
    [["123456789012345678901"],[[1,"1","x"],null,"1759800000000000"]]],\#
    [[null,"1"],[2,"123456789012345678902"],[["123456789012345678902"],[]]]]]
    """#

    private func time(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }

    @Test func calendarEntriesCarryTheirKeyAndStatus() throws {
        let answer = try #require(PeopleStackAnswer(Data(Self.answer.utf8)))
        #expect(answer.calendar.map(\.key)
            == [.email("me@example.invalid"), .personID("123456789012345678902")])
        #expect(answer.calendar.map(\.status) == [nil, 5])
        #expect(answer.calendar[1].payload == nil)
    }

    @Test func theIntervalsAreReadInOrderWithTheirStatusMember() throws {
        let calendar = try #require(PeopleStackAnswer(Data(Self.answer.utf8))?.calendar.first?.payload)
        #expect(calendar.intervals.map(\.member) == [5, 2, 3])
        #expect(calendar.intervals.map(\.start)
            == [time(1_759_690_000.5), time(1_759_693_600), time(1_759_697_200)])
        #expect(calendar.intervals.map(\.end)
            == [time(1_759_693_600), time(1_759_697_200), time(1_759_700_800)])
        #expect(calendar.validUntil == time(1_759_777_200))
        #expect(calendar.trailingRows == 2)
        #expect(calendar.intervals.first?.contextName == "Area/Some_City")
    }

    /// Which field of the member's message holds which time is the code's
    /// reading, not a measurement (§62.6), so every timestamp field is kept
    /// by its number.
    @Test func aMeetingKeepsEveryTimeByFieldNumber() throws {
        let calendar = try #require(PeopleStackAnswer(Data(Self.answer.utf8))?.calendar.first?.payload)
        #expect(calendar.intervals[0].times == [
            2: time(1_759_600_000), 3: time(1_759_690_000), 4: time(1_759_693_600), 5: time(1_759_693_600)
        ])
        #expect(calendar.intervals[1].times.isEmpty)
        #expect(calendar.intervals[2].times == [2: time(1_759_700_800)])
    }

    @Test func theIntervalContainingADateIsFound() throws {
        let calendar = try #require(PeopleStackAnswer(Data(Self.answer.utf8))?.calendar.first?.payload)
        #expect(calendar.interval(at: time(1_759_691_000))?.member == 5)
        // An end is exclusive: the next interval starts there.
        #expect(calendar.interval(at: time(1_759_693_600))?.member == 2)
        #expect(calendar.interval(at: time(1_759_700_800)) == nil)
        #expect(calendar.interval(at: time(1_759_000_000)) == nil)
    }

    @Test func presenceAndCustomStatusAreReadPerPerson() throws {
        let answer = try #require(PeopleStackAnswer(Data(Self.answer.utf8)))
        #expect(answer.presence.map(\.payload) == [1, 3])
        #expect(answer.userStatus.map(\.payload) == [true, false])
        #expect(answer.presence.map(\.key) == [
            .personID("123456789012345678901"), .personID("123456789012345678902")
        ])
    }

    @Test func anXSSIPrefixIsTolerated() {
        #expect(PeopleStackAnswer(Data((")]}'\n" + Self.answer).utf8))?.calendar.count == 2)
    }

    /// Google's `json+protobuf` error is also an array, `[code, "message"]`;
    /// an answer's first field is a string.
    @Test func anErrorBodyIsNotAnAnswer() {
        let error = #"[401,"Request had invalid authentication credentials."]"#
        #expect(PeopleStackAnswer(Data(error.utf8)) == nil)
        #expect(PeopleStackAnswer(Data("<html>".utf8)) == nil)
    }

    // MARK: - The key in the bundle

    /// Built at run time, so no literal in this file looks like a Google API
    /// key to a secret scanner.
    private static let prodKey = "AI" + "za" + String(repeating: "P", count: 35)
    private static let otherKey = "AI" + "za" + String(repeating: "Q", count: 35)
    private static let devKey = String(repeating: "D", count: 39)
    private static let origin = "https://chat.google.com"

    @Test func theConfigLiteralsKeyComesFirstThenEveryOtherKeyOnce() {
        let bundle = #"var a="\#(Self.otherKey)";x=[1,[true,135],false,"#
            + #"[null,null,"\#(Self.devKey)","\#(Self.prodKey)"]];b='\#(Self.otherKey)';"#
        #expect(PeopleStackKey.candidates(inBundle: bundle) == [Self.prodKey, Self.otherKey])
        #expect(PeopleStackKey.configKey(inBundle: bundle) == Self.prodKey)
        #expect(PeopleStackKey.configKey(inBundle: #"b="\#(Self.otherKey)";"#) == nil)
    }

    @Test func aLongerRunIsNotAKey() {
        let bundle = #"x="\#(Self.prodKey)Z";"#
        #expect(PeopleStackKey.candidates(inBundle: bundle).isEmpty)
    }

    @Test func theModuleAddressReplacesThePagesModuleList() throws {
        let page = #"<link rel="preload" href="/_/scs/mss-static/_/js/k=boq-dynamite.DynamiteWebUi.en.v1.O/"#
            + #"am=AAAA/d=1/excm=_b,_tp/ed=1/rs=RRRR/m=_b,_tp" as="script">"#
        let url = try #require(PeopleStackKey.moduleURL(inPage: page, module: "F41ord", origin: Self.origin))
        #expect(url.absoluteString == "https://chat.google.com/_/scs/mss-static/_/js/"
            + "k=boq-dynamite.DynamiteWebUi.en.v1.O/am=AAAA/d=1/ed=1/rs=RRRR/m=F41ord")
    }

    @Test func anAbsoluteOrEscapedAddressIsReadToo() throws {
        let page = #"{"src":"https:\/\/chat.google.com\/_\/scs\/mss-static\/_\/js\/k\u003dboq-dynamite.X.O\/"#
            + #"exm\u003da,b\/m\u003dc"}"#
        let url = try #require(PeopleStackKey.moduleURL(inPage: page, module: "F41ord", origin: Self.origin))
        #expect(url.absoluteString
            == "https://chat.google.com/_/scs/mss-static/_/js/k=boq-dynamite.X.O/m=F41ord")
    }

    @Test func aPageWithNoBundleAddressHasNoModuleURL() {
        let url = PeopleStackKey.moduleURL(inPage: "<html></html>", module: "F41ord", origin: Self.origin)
        #expect(url == nil)
    }
}
