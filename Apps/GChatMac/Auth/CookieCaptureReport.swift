import Foundation

/// What a capture found, in a form that is safe to print, log and commit.
///
/// **Names, counts and lengths. Never a value.** The repo's standing rule, and
/// here it costs nothing: the pass criterion for the login spike is a set of
/// names, so the safe report is also the complete answer.
struct CookieCaptureReport: Sendable {
    struct Entry: Sendable {
        let name: String
        let domain: String
        let valueLength: Int
        let isHTTPOnly: Bool
        let isSecure: Bool
        let expiresInDays: Int?
    }

    let capturedAt: Date
    let pageURL: String
    let pageTitle: String
    let entries: [Entry]

    var totalHeaderLength: Int {
        entries.reduce(0) { $0 + $1.name.count + 1 + $1.valueLength + 2 }
    }

    var names: Set<String> {
        Set(entries.map(\.name))
    }

    /// The two that are scoped to `chat.google.com` and set by Chat itself, so
    /// their presence is what distinguishes "the person signed in" from "Chat
    /// has actually loaded and issued its own cookies".
    var hasChatScopedCookies: Bool {
        names.contains("COMPASS") && names.contains("OSID")
    }

    /// The modern-auth family, which rides on `.google.com` and therefore shows
    /// up long before Chat's own cookies do. Present-without-the-above is
    /// exactly the convincing-looking failure that cost session 3 three
    /// re-captures.
    var hasModernAuthFamily: Bool {
        names.contains("__Secure-1PSID") || names.contains("__Secure-3PSID")
    }

    /// `HttpOnly` cookies are invisible to in-page JavaScript. Seeing any at all
    /// is the evidence that the *native* store hands over what a scraper could
    /// not - which is the linchpin the architecture design names.
    var httpOnlyCount: Int {
        entries.count(where: \.isHTTPOnly)
    }

    var verdict: String {
        switch (hasChatScopedCookies, hasModernAuthFamily) {
        case (true, true):
            "PASS — Chat-scoped cookies and the modern-auth family are both present"
        case (false, true):
            "TOO EARLY — signed in, but Chat has not issued COMPASS/OSID yet"
        case (true, false):
            "ODD — Chat-scoped cookies without the modern-auth family; investigate"
        case (false, false):
            "NOT SIGNED IN — neither family present"
        }
    }

    /// Deliberately the whole report: there is nothing here that has to be
    /// redacted before pasting it into an issue.
    var text: String {
        var lines = [
            "GChat cookie capture report",
            "captured: \(capturedAt.formatted(.iso8601))",
            "page:     \(pageURL)",
            "title:    \(pageTitle)",
            "",
            "verdict:  \(verdict)",
            "cookies:  \(entries.count)  (\(httpOnlyCount) HttpOnly)",
            "header:   \(totalHeaderLength) bytes",
            "COMPASS:  \(names.contains("COMPASS") ? "present" : "MISSING")",
            "OSID:     \(names.contains("OSID") ? "present" : "MISSING")",
            "",
            String(format: "%-34s %-22s %6s %5s %5s %s", "NAME", "DOMAIN", "LEN", "HTTP", "SEC", "EXPIRES")
        ]
        for entry in entries.sorted(by: { $0.name < $1.name }) {
            lines.append(
                String(
                    format: "%-34s %-22s %6d %5s %5s %s",
                    entry.name,
                    entry.domain,
                    entry.valueLength,
                    entry.isHTTPOnly ? "yes" : "no",
                    entry.isSecure ? "yes" : "no",
                    entry.expiresInDays.map { "\($0)d" } ?? "session"
                )
            )
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
