import Foundation

/// A timestamped log of what the login web view did.
///
/// Exists because "the button does nothing" has at least four causes that look
/// identical from outside: a popup the web view silently dropped, a navigation
/// refused by policy, a failed load, or clicks never reaching the view. Each
/// leaves a different trace, and none of them leaves a visible one.
///
/// URLs are recorded **path-only, with the query stripped**. Google's sign-in
/// URLs carry identifiers and one-time tokens in their query strings, and this
/// file is meant to be readable and pasteable.
@MainActor
enum LoginTrace {
    private(set) static var lines: [String] = []

    static func note(_ message: String) {
        let stamp = Date().formatted(date: .omitted, time: .standard)
        lines.append("\(stamp)  \(message)")
        flush()
    }

    static func note(_ message: String, url: URL?) {
        note("\(message) \(redact(url))")
    }

    /// Host and path only. A sign-in query string is full of tokens.
    static func redact(_ url: URL?) -> String {
        guard let url else { return "(no url)" }
        guard let host = url.host() else { return url.scheme ?? "(opaque)" }
        let query = url.query() == nil ? "" : " ?<stripped>"
        return "\(host)\(url.path())\(query)"
    }

    private static func flush() {
        guard let directory = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("GChat", isDirectory: true) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? lines.joined(separator: "\n").appending("\n").write(
            to: directory.appendingPathComponent("login-trace.txt"),
            atomically: true,
            encoding: .utf8
        )
    }
}
