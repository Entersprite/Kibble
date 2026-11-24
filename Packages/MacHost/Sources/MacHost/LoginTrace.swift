import Foundation
import WebKit

/// A timestamped log of what the login web view did.
///
/// Exists because "the button does nothing" has at least four causes that look
/// identical from outside: a popup the web view silently dropped, a navigation
/// refused by policy, a failed load, or clicks never reaching the view. Each
/// leaves a different trace, and none of them leaves a visible one.
///
/// The trace records fixed navigation stages. URLs, page text and raw errors
/// can include account identifiers or one-time values.
@MainActor
public enum LoginTrace {
    private(set) static var lines: [String] = []

    public static func note(_ message: String) {
        let stamp = Date().formatted(date: .omitted, time: .standard)
        lines.append("\(stamp)  \(message)")
        if lines.count > 120 {
            lines.removeFirst(lines.count - 120)
        }
        flush()
    }

    public static func note(_ message: String, url: URL?) {
        note("\(message) [\(LoginPageLocation(url).rawValue)]")
    }

    static func safeFailure(_ error: any Error) -> String {
        let error = error as NSError
        switch (error.domain, error.code) {
        case (NSURLErrorDomain, NSURLErrorNotConnectedToInternet): return "This Mac appears to be offline."
        case (NSURLErrorDomain, NSURLErrorTimedOut): return "The page took too long to load."
        case (NSURLErrorDomain, NSURLErrorSecureConnectionFailed):
            return "A secure connection couldn’t be made."
        case (WKError.errorDomain, WKError.Code.webContentProcessTerminated.rawValue):
            return "The browser page closed unexpectedly."
        default: return "The page couldn’t be loaded."
        }
    }

    /// Host and path only. A sign-in query string is full of tokens.
    public static func redact(_ url: URL?) -> String {
        guard let url else { return "(no url)" }
        guard let host = url.host() else { return url.scheme ?? "(opaque)" }
        let query = url.query() == nil ? "" : " ?<stripped>"
        return "\(host)\(url.path())\(query)"
    }

    private static func flush() {
        guard let directory = try? SystemLaunchServices.supportDirectory() else { return }
        try? lines.joined(separator: "\n").appending("\n").write(
            to: directory.appendingPathComponent("login-trace.txt"),
            atomically: true,
            encoding: .utf8
        )
    }
}
