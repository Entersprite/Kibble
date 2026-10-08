import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// The calendar poll (meeting indicator spec §3.1): who is asked, how, and
/// what reaches the event stream.
@Suite(.timeLimit(.minutes(1)))
struct CalendarPollTests {
    private static let cookies = SessionCookies(cookies: [
        SessionCookies.Cookie(name: "SID", value: "a", domain: ".google.com", path: "/"),
        SessionCookies.Cookie(name: "SAPISID", value: "sap-1", domain: ".google.com", path: "/")
    ])!

    private let me = ChatKit.Member.ID("u-me")
    private let ada = ChatKit.Member.ID("u-1")
    private let now = Int(Date().timeIntervalSince1970)

    private func backend(
        _ transport: CalendarTransport,
        interval: Duration = .seconds(3600)
    ) async -> LocalBridgeBackend {
        let backend = LocalBridgeBackend(cookies: Self.cookies, transport: transport, retry: .default)
        await backend.setCalendarPollInterval(interval)
        return backend
    }

    /// A meeting from 10 minutes ago to `end` seconds from now, for each id;
    /// "not found" for each id in `notFound`.
    private func answer(_ ids: [String], end: Int = 3600, notFound: [String] = []) -> String {
        let (start, stop, valid) = (now - 600, now + end, now + 43200)
        let meeting = "[null,null,null,null,[null,[\"\(stop)\"],[\"\(stop)\"],[\"\(stop)\"],[\"\(stop)\"]]]"
        let found = ids.map { id in
            #"[[null,"1"],[2,"\#(id)"],[[[[["\#(start)"],["\#(stop)"]],\#(meeting)]],["\#(valid)"]]]"#
        }
        let missing = notFound.map { #"[[5,"1"],[2,"\#($0)"]]"# }
        return #"["1",[\#((found + missing).joined(separator: ","))]]"#
    }

    private func meeting(end: Int = 3600) -> CalendarSchedule {
        let stop = Date(timeIntervalSince1970: TimeInterval(now + end))
        return CalendarSchedule(
            entries: [.init(
                start: Date(timeIntervalSince1970: TimeInterval(now - 600)), end: stop, kind: .inMeeting,
                until: stop
            )],
            validUntil: Date(timeIntervalSince1970: TimeInterval(now + 43200))
        )
    }

    private func awaitCalendarRequests(_ count: Int, on transport: CalendarTransport) async throws {
        for _ in 0 ..< 400 where await transport.calendarRequests.count < count {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(await transport.calendarRequests.count >= count)
    }

    private func calendars(in events: [ChatEvent]) -> [ChatKit.Member.ID: [CalendarSchedule?]] {
        var result: [ChatKit.Member.ID: [CalendarSchedule?]] = [:]
        for case let .calendarChanged(member, schedule) in events {
            result[member, default: []].append(schedule)
        }
        return result
    }

    private func calendarErrors(in events: [ChatEvent]) -> Int {
        events.count {
            if case let .backendError(error) = $0 {
                return "\(error)".contains("calendar status")
            }
            return false
        }
    }

    @Test func theWorldLoadAsksAboutDMMembersInOneSignedRequest() async throws {
        let transport = CalendarTransport(answers: [.json(answer(["u-1", "u-me"]))])
        let backend = await backend(transport)
        let log = SenderEventLog(backend)
        try await backend.connect()

        _ = try await backend.loadConversations()
        try await awaitCalendarRequests(1, on: transport)
        let events = await log.settle()

        let request = try #require(await transport.calendarRequests.first)
        #expect(request.url.host == "peoplestack-pa.clients6.google.com")
        #expect(String(decoding: request.body ?? Data(), as: UTF8.self)
            == #"[[1,"1"],[[[[2,"u-1"],[2,"u-me"]],[1]]]]"#)
        #expect(request.headers.all("X-Goog-Api-Key") == ["tzliq-key"])
        let authorization = try #require(request.headers.all("Authorization").first)
        #expect(authorization
            .range(of: #"^SAPISIDHASH \d+_[0-9a-f]{40}$"#, options: .regularExpression) != nil)
        #expect(calendars(in: events) == [ada: [meeting()], me: [meeting()]])
        await backend.disconnect()
    }

    /// The first run waits for every name lookup, so its UPDATE lands.
    @Test func theFirstRunWaitsForTheNameLookups() async throws {
        let transport = CalendarTransport(answers: [.json(answer(["u-1", "u-me"]))], heldLookups: 2)
        let backend = await backend(transport)
        try await backend.connect()

        _ = try await backend.loadConversations()
        try await Task.sleep(for: .milliseconds(200))
        #expect(await transport.calendarRequests.isEmpty)
        await transport.release()
        try await awaitCalendarRequests(1, on: transport)
        await backend.disconnect()
    }

    /// With no one-to-one DM, nothing else creates the local user's row: the
    /// first run waits for their own lookup, held here (review finding 2).
    @Test func withNoDMTheFirstRunWaitsForTheLocalUsersLookup() async throws {
        let transport = CalendarTransport(partners: [], answers: [.json(answer(["u-me"]))], heldLookups: 1)
        let backend = await backend(transport, interval: .milliseconds(20))
        try await backend.connect()

        _ = try await backend.loadConversations()
        try await Task.sleep(for: .milliseconds(200))
        #expect(await transport.calendarRequests.isEmpty)
        await transport.release()
        try await awaitCalendarRequests(1, on: transport)
        let body = await transport.calendarRequests.first.map { String(decoding: $0.body ?? Data(), as: UTF8.self) }
        #expect(body == #"[[1,"1"],[[[[2,"u-me"]],[1]]]]"#)
        await backend.disconnect()
    }

    /// A poll that learns nothing new emits nothing; a change emits once.
    @Test func onlyChangesAreEmitted() async throws {
        let transport = CalendarTransport(answers: [
            .json(answer(["u-1"])), .json(answer(["u-1"])), .json(answer(["u-1"], end: 7200))
        ])
        let backend = await backend(transport, interval: .milliseconds(20))
        let log = SenderEventLog(backend)
        try await backend.connect()

        _ = try await backend.loadConversations()
        try await awaitCalendarRequests(4, on: transport)
        let events = await log.settle()

        #expect(calendars(in: events)[ada] == [meeting(), meeting(end: 7200)])
        await backend.disconnect()
    }

    @Test func someoneNotFoundAfterAMeetingIsCleared() async throws {
        let transport = CalendarTransport(answers: [
            .json(answer(["u-1"])), .json(answer([], notFound: ["u-1"]))
        ])
        let backend = await backend(transport, interval: .milliseconds(20))
        let log = SenderEventLog(backend)
        try await backend.connect()

        _ = try await backend.loadConversations()
        try await awaitCalendarRequests(3, on: transport)
        let events = await log.settle()

        #expect(calendars(in: events)[ada] == [meeting(), nil])
        await backend.disconnect()
    }

    /// One error per run of failures, and what was shown stays: a schedule is
    /// still true while a fetch fails.
    @Test func failuresAreReportedOncePerRunAndSchedulesKept() async throws {
        let transport = CalendarTransport(answers: [
            .json(answer(["u-1"])), .failure, .failure, .json(answer(["u-1"])), .failure
        ])
        let backend = await backend(transport, interval: .milliseconds(20))
        let log = SenderEventLog(backend)
        try await backend.connect()

        _ = try await backend.loadConversations()
        try await awaitCalendarRequests(6, on: transport)
        let events = await log.settle()

        #expect(calendars(in: events)[ada] == [meeting()])
        #expect(calendarErrors(in: events) == 2)
        await backend.disconnect()
    }

    @Test func moreThan25PeopleGoInBatches() async throws {
        let ids = (1 ... 30).map { "p-\($0)" }
        let transport = CalendarTransport(partners: ids, answers: [.json(answer(["p-1"]))])
        let backend = await backend(transport)
        try await backend.connect()

        _ = try await backend.loadConversations()
        try await awaitCalendarRequests(2, on: transport)

        let bodies = await transport.calendarRequests
            .map { String(decoding: $0.body ?? Data(), as: UTF8.self) }
        #expect(bodies.map { $0.components(separatedBy: "[2,").count - 1 } == [25, 6])
        await backend.disconnect()
    }

    /// An answer that comes back after the session ended lands nowhere.
    @Test func aStaleAnswerIsDroppedAfterDisconnect() async throws {
        let transport = CalendarTransport(answers: [.json(answer(["u-1", "u-me"]))], holdCalendarAt: 0)
        let backend = await backend(transport)
        let log = SenderEventLog(backend)
        try await backend.connect()

        _ = try await backend.loadConversations()
        try await awaitCalendarRequests(1, on: transport)
        await backend.disconnect()
        await transport.release()
        for _ in 0 ..< 400 where await transport.calendarAnswered < 1 {
            try await Task.sleep(for: .milliseconds(5))
        }
        let events = await log.settle()

        #expect(calendars(in: events).isEmpty)
    }

    /// With no people search key, the people search has already said so once:
    /// the calendar sends nothing and adds no second error.
    @Test func noKeyMeansNoRequestAndNoCalendarError() async throws {
        let transport = CalendarTransport(key: nil, answers: [.json(answer(["u-1"]))])
        let backend = await backend(transport)
        let log = SenderEventLog(backend)
        try await backend.connect()

        _ = try await backend.loadConversations()
        let events = await log.settle()

        #expect(await transport.calendarRequests.isEmpty)
        #expect(calendarErrors(in: events) == 0)
        await backend.disconnect()
    }
}
