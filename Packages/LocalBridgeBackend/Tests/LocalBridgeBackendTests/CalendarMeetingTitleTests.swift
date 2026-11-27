import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

struct CalendarMeetingTitleTests {
    @Test func theExistingAccountReadsCalendarTitlesAndResolvesMovedOccurrences() async throws {
        let first = try Date("2026-11-23T17:00:00Z", strategy: .iso8601)
        let original = try Date("2026-11-30T17:00:00Z", strategy: .iso8601)
        let moved = original.addingTimeInterval(-1800)
        let events = [
            Self.event("weekly-1", "Weekly review", start: first),
            Self.event("weekly-2", "Moved review", start: moved, original: original),
            Self.event("weekly-3", "Cancelled review", start: original.addingTimeInterval(604_800), status: 2)
        ]
        let transport = try CalendarMeetingTitleTransport(
            email: "owner@example.test", events: events,
            shared: [Self.event("weekly-2", "Old copy", start: original, original: original)],
            redirects: true
        )
        let backend = makeBackend(transport)
        await backend.seedCalendarOwner("owner@example.test")
        let url = try #require(URL(string: "https://meet.google.com/abc-defg-hij?authuser=4"))
        let link = try MeetJoinLink(url)
        #expect(try await backend.calendarMeetingTitle(link, at: first) == "Weekly review")
        #expect(try await backend.calendarMeetingTitle(link, at: moved) == "Moved review")
        #expect(try await backend.calendarMeetingTitle(link, at: original) == "Moved review")
        let requests = await transport.requests
        #expect(requests.count == 6)
        #expect(requests.filter { $0.url.path() == "/calendar/u/0/r/week" }.count == 2)
        #expect(requests.allSatisfy { $0.url.host() == "calendar.google.com" && !$0.followsRedirects })
        #expect(requests.allSatisfy { $0.headers["Cookie"] == "SID=fixture" })
        let read = try #require(requests.last)
        #expect(read.url.path() == "/calendar/u/0/sync.fetcheventrange")
        #expect(read.method == .post)
        let encoded = String(decoding: read.body ?? Data(), as: UTF8.self)
        let query = try #require(URLComponents(string: "?" + encoded)?.queryItems)
        let payload = try #require(query.first { $0.name == "f.req" }?.value)
        let form = try JSONDecoder().decode(PBLiteValue.self, from: Data(payload.utf8))
        let fields = try #require(form.arrayValue?.first?.arrayValue)
        #expect(fields.first?.arrayValue?.compactMap(\.stringValue) == [
            "owner@example.test",
            "shared@example.test"
        ])
        let context = try #require(fields[2].arrayValue)
        #expect(context[1].intValue == 3)
        #expect(context[7].intValue == 100)
        #expect(context[9].stringValue == "WEB")
        #expect(context[10].stringValue == "calendar-web-fixture")
        #expect(query.first { $0.name == "secid" }?.value == "calendar-web-token")
    }

    @Test func aCalendarPageForADifferentGoogleAccountNeverGetsAnEventRequest() async throws {
        let transport = try CalendarMeetingTitleTransport(email: "other@example.test", events: [], shared: [])
        let backend = makeBackend(transport)
        await backend.seedCalendarOwner("owner@example.test")
        let url = try #require(URL(string: "https://meet.google.com/abc-defg-hij"))
        let link = try MeetJoinLink(url)
        await #expect(throws: (any Error).self) {
            _ = try await backend.calendarMeetingTitle(link, at: Date(timeIntervalSince1970: 1_800_000_000))
        }
        #expect(await transport.requests.count == 1)
    }

    @Test func aSignInRedirectRequestsRecoveryWithoutFollowingIt() async throws {
        let transport = try CalendarMeetingTitleTransport(
            email: "owner@example.test", events: [], shared: [], signInRequired: true
        )
        let backend = makeBackend(transport)
        await backend.seedCalendarOwner("owner@example.test")
        let link = try MeetJoinLink(#require(URL(string: "https://meet.google.com/abc-defg-hij")))
        await #expect(throws: CalendarWebEventClient.SessionFailure.signInRequired) {
            _ = try await backend.calendarMeetingTitle(link, at: .now)
        }
        #expect(await backend.checkCalendarMeetingTitleAccess() == false)
        let requests = await transport.requests
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.url.host() == "calendar.google.com" })
    }

    @Test func aSuccessfulReadOfAnEmptyCalendarReportsConnected() async throws {
        let backend = try makeBackend(CalendarMeetingTitleTransport(
            email: "owner@example.test",
            events: [],
            shared: []
        ))
        await backend.seedCalendarOwner("owner@example.test")
        #expect(await backend.checkCalendarMeetingTitleAccess())
    }

    @Test(arguments: [true, false])
    func webSignInKeepsTheVerifiedBrowserSessionScopedToCalendar(matchesAccount: Bool) async throws {
        let transport = try CalendarMeetingTitleTransport(
            email: matchesAccount ? "owner@example.test" : "other@example.test", events: [], shared: []
        )
        let backend = makeBackend(transport)
        await backend.seedCalendarOwner("owner@example.test")
        let store = KeychainCredentialStore(storage: CalendarSignInTestSecrets(), account: "calendar-sign-in")
        let original = try #require(await backend.credentials.snapshot)
        try await store.store(StoredSession(credential: original, capturedAt: .now, expiresAt: nil))
        let expected = try #require(try await store.summary(at: .now))
        let browser = [
            Self.capturedCookie("SID", "different-parent", domain: ".google.com"),
            Self.capturedCookie("OSID", "calendar-session", domain: "calendar.google.com"),
            Self.capturedCookie("OSID", "different-chat", domain: "chat.google.com")
        ]
        if matchesAccount {
            #expect(try await backend.saveCalendarSignIn(browser, to: store, expected: expected) == 2)
            try await store.replaceCredential(with: original)
        } else {
            await #expect(throws: MeetWebCaptureError.accountMismatch) {
                _ = try await backend.saveCalendarSignIn(browser, to: store, expected: expected)
            }
        }
        let stored = try #require(try await store.snapshot())
        let live = try #require(await backend.credentials.snapshot)
        #expect(stored.session.credential == live)
        #expect(stored.session.credential["SID"] == "fixture")
        #expect(stored.calendarSession?.credential["SID"] == (matchesAccount ? "different-parent" : nil))
        #expect(stored.calendarSession?.credential["OSID"] == (matchesAccount ? "calendar-session" : nil))
        let requests = await transport.requests
        #expect(requests.count == 1)
        #expect(requests.allSatisfy { $0.headers["Cookie"] == "SID=different-parent; OSID=calendar-session" })
    }

    private static func capturedCookie(_ name: String, _ value: String, domain: String) -> CapturedCookie {
        CapturedCookie(
            name: name, value: value, domain: domain, path: "/",
            isSecure: true, isHTTPOnly: true, expiresAt: nil
        )
    }

    private func makeBackend(_ transport: CalendarMeetingTitleTransport) -> LocalBridgeBackend {
        let cookies = SessionCookies(cookies: [
            .init(name: "SID", value: "fixture", domain: ".google.com", path: "/"),
            .init(name: "private-chat", value: "fixture", domain: "chat.google.com", path: "/")
        ])!
        return LocalBridgeBackend(cookies: cookies, transport: transport, retry: .default)
    }

    private static func event(
        _ id: String, _ title: String, start: Date, original: Date? = nil, status: Int64 = 0
    ) -> PBLiteValue {
        func timed(_ instant: Date) -> PBLiteValue {
            .array([.null, .array([.string(String(Int64(instant.timeIntervalSince1970 * 1000)))])])
        }
        return .array([.string(id), .number(.integer(status)), .null, .null, .null, .string(title), .object([
            "36": timed(start), "37": timed(start.addingTimeInterval(3600)), "38": timed(original ?? start),
            "58": .array([.array([.array([
                .number(.integer(1)),
                .string("https://meet.google.com/abc-defg-hij")
            ])])])
        ])])
    }
}

private actor CalendarMeetingTitleTransport: HTTPTransport {
    var requests: [HTTPRequest] = []
    let page: Data
    let range: Data
    let redirects: Bool
    let signInRequired: Bool

    init(
        email: String, events: [PBLiteValue], shared: [PBLiteValue],
        redirects: Bool = false, signInRequired: Bool = false
    ) throws {
        self.redirects = redirects
        self.signInRequired = signInRequired
        let accounts = """
        <script id="initialdata" type="application/json">[[null,null,"\(email)"],
        {"27":"calendar-web-token","29":"calendar-web-fixture","37":1,"45":"100",
        "40":[null,[[null,[[null,["\(email)",null,null,4,null,1]],
        [null,["shared@example.test",null,null,2]],[null,["busy@example.test",null,null,1]]]]]]}]</script>
        """
        page = Data(accounts.utf8)
        let groups: [PBLiteValue] = [
            .array([.string(email), .array(events)]),
            .array([.string("shared@example.test"), .array(shared)])
        ]
        let response: PBLiteValue = .array([.array([
            .string("fetcheventrangeaction.ferr"), .null, .array([.null, .array(groups)])
        ])])
        range = try Data(")]}'\n".utf8) + (JSONEncoder().encode(response))
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        if request.method == .get, request.url.path().hasSuffix("/r"), redirects || signInRequired {
            let location = signInRequired
                ? "https://accounts.google.com/ServiceLogin" : "/calendar/u/0/r/week"
            return HTTPResponse(
                status: 302,
                headers: .init([("Location", location)]),
                body: Data(),
                url: request.url
            )
        }
        let response = request.method == .get ? page : range
        return HTTPResponse(status: 200, headers: .init([]), body: response, url: request.url)
    }

    func stream(_: HTTPRequest) async throws -> HTTPStream {
        throw CancellationError()
    }
}

private extension LocalBridgeBackend {
    func seedCalendarOwner(_ email: String) {
        let selfID = Member.ID("owner")
        isConnected = true
        calendarPoll.me = selfID
        memberEmails[selfID] = email
    }
}

private final class CalendarSignInTestSecrets: SecretStorage, @unchecked Sendable {
    private var data: Data?
    private let lock = NSLock()

    func read(account _: String) -> Data? {
        lock.withLock { data }
    }

    func write(_ data: Data, account _: String) {
        lock.withLock { self.data = data }
    }

    func delete(account _: String) {
        lock.withLock { data = nil }
    }
}
