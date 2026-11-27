import Foundation

/// Read-only calls to the signed-in Calendar web client. Credentials stay in
/// the same scoped cookie jar used by the account's Chat and Meet operations.
public struct CalendarWebEventClient: Sendable {
    public enum SessionFailure: Error {
        case signInRequired
        case wrongAccount
    }

    let transport: any HTTPTransport
    let credentials: SessionCredentials
    let endpoints: ChatEndpoints

    public init(transport: any HTTPTransport, credentials: SessionCredentials, endpoints: ChatEndpoints) {
        self.transport = transport
        self.credentials = credentials
        self.endpoints = endpoints
    }

    public func validateSession(
        email: String,
        report: @Sendable (String, Int) -> Void = { _, _ in }
    ) async throws {
        let browser = try await browserCredentials()
        _ = try await loadBootstrap(calendarBase(), email: email, credentials: browser, report: report)
    }

    public func occurrences(
        around day: Date, email: String, report: @Sendable (String, Int) -> Void = { _, _ in }
    ) async throws -> [CalendarWebOccurrence] {
        let browser = try await browserCredentials()
        let base = try calendarBase()
        let (bootstrap, referrer) = try await loadBootstrap(
            base,
            email: email,
            credentials: browser,
            report: report
        )
        var fields = try CalendarWebWire.rangeForm(bootstrap, around: day)
        let url = base.appendingPathComponent("sync.fetcheventrange")
        var reply = try await send(
            rangeRequest(url, page: referrer, fields: fields),
            credentials: browser,
            report: report
        )
        if reply.status == 403, let refreshed = reply.headers["X-New-Security-Id"],
           refreshed.utf8.count <= 1024 {
            fields.removeAll { $0.0 == "secid" }
            fields.append(("secid", refreshed))
            reply = try await send(
                rangeRequest(url, page: referrer, fields: fields),
                credentials: browser,
                report: report
            )
        }
        guard reply.status == 200 else { throw CalendarWebWire.Failure.unavailable }
        let occurrences = try CalendarWebWire.occurrences(reply.body, bootstrap: bootstrap, report: report)
        report("meeting-occurrences", occurrences.count)
        return occurrences
    }

    private func browserCredentials() async throws -> SessionCredentials {
        guard let snapshot = await credentials.snapshot else { throw CalendarWebWire.Failure.unavailable }
        return SessionCredentials(snapshot)
    }

    private func loadBootstrap(
        _ base: URL, email: String, credentials: SessionCredentials, report: @Sendable (String, Int) -> Void
    ) async throws -> (CalendarWebWire.Bootstrap, URL) {
        let page = base.appendingPathComponent("r")
        let initial = try await send(HTTPRequest(
            url: page, headers: HTTPHeaders([("User-Agent", endpoints.userAgent)]),
            timeout: .seconds(4), traceLabel: "calendar-web-session", followsRedirects: false,
            maxBodyBytes: 3 * 1024 * 1024
        ), credentials: credentials, redirectUnder: base, report: report)
        report("bootstrap-marker", initial.body.range(of: Data("initialdata".utf8)) == nil ? 0 : 1)
        let bootstrap = try CalendarWebWire.bootstrap(initial.body, accountEmail: email)
        report("calendar-count", bootstrap.calendars.count)
        let referrer = initial.url ?? page
        await credentials.absorb(initial.headers, from: referrer)
        return (bootstrap, referrer)
    }

    private func calendarBase() throws -> URL {
        let index: Int = switch endpoints.account {
        case let .index(value): value
        case .none: 0
        }
        guard (0 ... 99).contains(index) else { throw CalendarWebWire.Failure.unavailable }
        return URL(string: "https://calendar.google.com/calendar/u/\(index)")!
    }

    private func rangeRequest(_ url: URL, page: URL, fields: [(String, String)]) -> HTTPRequest {
        HTTPRequest(
            method: .post,
            url: url,
            headers: HTTPHeaders([
                ("User-Agent", endpoints.userAgent), ("Content-Type", "application/x-www-form-urlencoded"),
                ("Origin", "https://calendar.google.com"), ("Referer", page.absoluteString),
                ("X-If-No-Redirect", "1"), ("X-Is-Xhr-Request", "1")
            ]),
            body: Data(QueryEncoding.query(fields).utf8), timeout: .seconds(4),
            traceLabel: "calendar-web-range", followsRedirects: false, maxBodyBytes: 4 * 1024 * 1024
        )
    }

    private func send(
        _ request: HTTPRequest, credentials: SessionCredentials, redirectUnder base: URL? = nil,
        redirectsLeft: Int = 5,
        report: @Sendable (String, Int) -> Void
    ) async throws -> HTTPResponse {
        try Task.checkCancellation()
        let scoped = await credentials.authorising(request)
        guard scoped.headers["Cookie"] != nil else {
            report("no-cookies", 0)
            throw CalendarWebWire.Failure.unavailable
        }
        let response = try await transport.send(scoped)
        report(request.traceLabel ?? "response", response.status)
        if let base, response.isRedirect,
           let location = response.headers["Location"],
           let target = URL(string: location, relativeTo: request.url)?.absoluteURL {
            let onCalendar = target.host() == base.host()
            let path = base.path + "/r"
            let inAccount = target.path == path || target.path.hasPrefix(path + "/")
            if target.host() == "accounts.google.com" {
                report("sign-in-required", 1)
                throw SessionFailure.signInRequired
            }
            if onCalendar, inAccount, redirectsLeft > 0, target != request.url,
               target.scheme == "https", target.user == nil, target.password == nil,
               target.port == nil || target.port == 443 {
                await credentials.absorb(response.headers, from: request.url)
                var redirect = request
                redirect.url = target
                return try await send(
                    redirect, credentials: credentials, redirectUnder: base, redirectsLeft: redirectsLeft - 1,
                    report: report
                )
            }
        }
        if base != nil, response.status != 200 {
            throw CalendarWebWire.Failure.unavailable
        }
        return response
    }
}
