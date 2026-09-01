import Foundation

/// What a login capture found, in a form that is safe to print, log and paste.
///
/// **Names, counts and lengths. Never a value.** The repo's standing rule, and
/// here it costs nothing: the pass criterion for the login spike is a set of
/// names, so the safe report is also the complete answer.
///
/// Lives in a package rather than in the app because the verdict rules below
/// are logic - and because a crash proved the rendering needs a test. The web
/// view that produces it stays in the app; this takes plain values.
public struct CookieCaptureReport: Sendable, Hashable {
    public struct Entry: Sendable, Hashable {
        public let name: String
        public let domain: String
        public let path: String
        public let valueLength: Int
        public let isHTTPOnly: Bool
        public let isSecure: Bool
        public let expiresInDays: Int?

        /// Whether this cookie is one a browser would send to Chat, and
        /// therefore one that reaches the credential.
        ///
        /// Recorded rather than filtered out: the excluded cookies are the
        /// evidence that the scoping is working, and the first version of this
        /// capture shipped without any and nobody could see it.
        public let isInScope: Bool

        public init(
            name: String,
            domain: String,
            path: String,
            valueLength: Int,
            isHTTPOnly: Bool,
            isSecure: Bool,
            expiresInDays: Int?,
            isInScope: Bool
        ) {
            self.name = name
            self.domain = domain
            self.path = path
            self.valueLength = valueLength
            self.isHTTPOnly = isHTTPOnly
            self.isSecure = isSecure
            self.expiresInDays = expiresInDays
            self.isInScope = isInScope
        }
    }

    public let capturedAt: Date
    public let pageURL: String
    public let pageTitle: String
    public let entries: [Entry]

    public init(capturedAt: Date, pageURL: String, pageTitle: String, entries: [Entry]) {
        self.capturedAt = capturedAt
        self.pageURL = pageURL
        self.pageTitle = pageTitle
        self.entries = entries
    }

    /// The cookies that will actually be replayed to Chat.
    ///
    /// Every question about the *credential* is asked of these, not of
    /// everything the store happened to hold. An out-of-scope `COMPASS` is a
    /// cookie for somewhere else and must not read as a pass.
    public var inScope: [Entry] {
        entries.filter(\.isInScope)
    }

    /// What the rebuilt `Cookie` header will weigh: `name=value; ` per entry.
    public var totalHeaderLength: Int {
        inScope.reduce(0) { $0 + $1.name.count + 1 + $1.valueLength + 2 }
    }

    public var names: Set<String> {
        Set(inScope.map(\.name))
    }

    /// The two cookies scoped to `chat.google.com` and issued by Chat itself,
    /// so their presence is what distinguishes "the person signed in" from
    /// "Chat has actually loaded and set its own cookies".
    public var hasChatScopedCookies: Bool {
        names.contains("COMPASS") && names.contains("OSID")
    }

    /// The modern-auth family, which rides on `.google.com` and therefore
    /// appears long before Chat's own cookies do. Present *without* the above
    /// is exactly the convincing-looking failure that cost session 3 three
    /// unnecessary re-captures.
    public var hasModernAuthFamily: Bool {
        names.contains("__Secure-1PSID") || names.contains("__Secure-3PSID")
    }

    /// `HttpOnly` cookies are invisible to in-page JavaScript, so seeing any at
    /// all is the evidence that the *native* store hands over what a scraper
    /// could not - the linchpin the architecture design names.
    public var httpOnlyCount: Int {
        entries.count(where: \.isHTTPOnly)
    }

    public var verdict: String {
        switch (hasChatScopedCookies, hasModernAuthFamily) {
        case (true, true):
            "PASS - Chat-scoped cookies and the modern-auth family are both present"
        case (false, true):
            "TOO EARLY - signed in, but Chat has not issued COMPASS/OSID yet"
        case (true, false):
            "ODD - Chat-scoped cookies without the modern-auth family; investigate"
        case (false, false):
            "NOT SIGNED IN - neither family present"
        }
    }

    /// The whole report as text. Nothing here needs redacting before it is
    /// pasted into an issue.
    ///
    /// Padded by hand rather than with `String(format:)`. That is not a style
    /// choice: `%s` expects a C string, and handing it a Swift `String` makes
    /// CoreFoundation walk the string's internals as a `char *`. It segfaulted
    /// the app the first time a real login reached this line.
    public var text: String {
        var lines = [
            "GChat cookie capture report",
            "captured: \(capturedAt.formatted(.iso8601))",
            "page:     \(pageURL)",
            "title:    \(pageTitle)",
            "",
            "verdict:  \(verdict)",
            "cookies:  \(entries.count) captured, \(inScope.count) sent to "
                + "\(Self.scopeHost)  (\(httpOnlyCount) HttpOnly)",
            "header:   \(totalHeaderLength) bytes",
            "COMPASS:  \(names.contains("COMPASS") ? "present" : "MISSING")",
            "OSID:     \(names.contains("OSID") ? "present" : "MISSING")",
            "",
            Self.header
        ]
        // Sent first, then excluded. The two groups answer different questions
        // - what the credential is, and what a browser would have withheld -
        // and interleaving them by name makes both harder to read.
        let sorted = entries.sorted {
            ($0.isInScope ? 0 : 1, $0.name) < ($1.isInScope ? 0 : 1, $1.name)
        }
        for entry in sorted {
            lines.append(Self.row(for: entry))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Named in the report so a reader knows which origin the scoping was
    /// against without going to look it up. Taken from the scope itself rather
    /// than restated, so the two cannot drift.
    public static var scopeHost: String {
        CookieCapture.scope.host
    }

    private static let header =
        pad("NAME", 34) + " " + pad("DOMAIN", 24) + " " + pad("LEN", 6)
            + " " + pad("HTTP", 5) + " " + pad("SEC", 5) + " "
            + pad("EXPIRES", 10) + " SENT"

    private static func row(for entry: Entry) -> String {
        pad(entry.name, 34) + " " + pad(entry.domain, 24)
            + " " + pad("\(entry.valueLength)", 6)
            + " " + pad(entry.isHTTPOnly ? "yes" : "no", 5)
            + " " + pad(entry.isSecure ? "yes" : "no", 5)
            + " " + pad(entry.expiresInDays.map { "\($0)d" } ?? "session", 10)
            + " " + (entry.isInScope ? "yes" : "excluded (\(entry.domain)\(entry.path))")
    }

    /// Left-aligned to `width`, never truncating: a cookie name that overflows
    /// the column should look ugly rather than be silently cut, because the
    /// name is the whole point of this report.
    private static func pad(_ value: String, _ width: Int) -> String {
        value.count >= width
            ? value
            : value + String(repeating: " ", count: width - value.count)
    }
}
