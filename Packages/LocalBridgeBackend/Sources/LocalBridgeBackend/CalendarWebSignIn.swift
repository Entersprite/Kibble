import Foundation
import GChatBridgeCore

enum CalendarWebSignIn {
    static let page = URL(string: "https://calendar.google.com/calendar/u/0/r")!
    static let range = URL(string: "https://calendar.google.com/calendar/u/0/sync.fetcheventrange")!

    static func admits(_ cookie: SessionCookies.Cookie) -> Bool {
        cookie.isSent(to: page) || cookie.isSent(to: range)
    }
}

public extension LocalBridgeBackend {
    func calendarSignInCookies() async throws -> [MeetWebCookieSeed] {
        let source = calendarPoll.titleCredentials ?? credentials
        guard isConnected, let cookies = await source.snapshot else { throw CancellationError() }
        return cookies.cookies.compactMap { cookie in
            guard let domain = cookie.domain, CalendarWebSignIn.admits(cookie) else { return nil }
            return .init(name: cookie.name, value: cookie.value, domain: domain, path: cookie.path ?? "/")
        }
    }

    func saveCalendarSignIn(
        _ captured: [CapturedCookie], to store: KeychainCredentialStore, expected: StoredSessionSummary
    ) async throws -> Int {
        let generation = directoryGeneration
        guard let owner = try await calendarTitleOwner(generation: generation),
              let capture = try await store.snapshot(), capture.generation == expected.custodyGeneration,
              capture.session.capturedAt == expected.capturedAt,
              capture.session.expiresAt == expected.expiresAt else { throw CancellationError() }
        let now = Date()
        let cookies = captured.compactMap { cookie -> SessionCookies.Cookie? in
            guard cookie.expiresAt.map({ $0 > now }) != false else { return nil }
            let value = SessionCookies.Cookie(
                name: cookie.name, value: cookie.value, domain: cookie.domain.lowercased(), path: cookie.path
            )
            return CalendarWebSignIn.admits(value) ? value : nil
        }
        guard let candidate = SessionCookies(cookies: cookies) else { return 0 }
        let client = CalendarWebEventClient(
            transport: transport, credentials: SessionCredentials(candidate), endpoints: endpoints
        )
        do {
            try await client.validateSession(email: owner) { [diagnostics] stage, value in
                diagnostics.record(.calendarWebRead(stage: stage, value: value))
            }
        } catch CalendarWebEventClient.SessionFailure.wrongAccount {
            throw MeetWebCaptureError.accountMismatch
        }
        try Task.checkCancellation()
        guard isConnected, directoryGeneration == generation else { throw CancellationError() }
        let session = StoredSession(credential: candidate, capturedAt: now, expiresAt: nil)
        try await store.installCalendarSession(session, expected: capture)
        guard isConnected, directoryGeneration == generation else { throw CancellationError() }
        installCalendarTitleCredentials(candidate)
        return cookies.count
    }

    internal func installCalendarTitleCredentials(_ cookies: SessionCookies) {
        calendarPoll.meetingTitles.cancel()
        calendarPoll.meetingTitles = CalendarMeetingTitles()
        calendarPoll.titleCredentials = SessionCredentials(cookies)
    }
}
