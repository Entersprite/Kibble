import Foundation
import GChatBridgeCore

/// Renders a Punctual push as its shape, for `--probe=punctual`.
///
/// No push has been seen yet (`findings.md` §46.6), so nothing here can know
/// which parts are harmless. **It masks by parsing, never by pattern**: the
/// value is already a parsed tree, and every leaf is judged on its own.
/// - A string that is a watched person's id becomes their label: `person N`,
///   or `self`.
/// - A string whose content is JSON is parsed and rendered as `json(…)`. Two
///   reads in session 35 leaked personal data through exactly this case, a
///   string nested inside a string.
/// - A string of five digits or fewer prints as itself, quoted: pushes name
///   a watch by its sequence that way. A longer one is a time (`@now-3m`)
///   when plausible, and otherwise `d<length>`, because it could be an id.
/// - A word from `vocabulary`, the words the capture's own requests and
///   answers use, is printed. Any other lowercase word becomes `w<length>`:
///   it could be a SID, a status someone typed (`lunch`) or a username, and
///   the review showed a lowercase SID printing in full. A `w<n>` where a
///   value is expected is the cue to add a word here after a run.
/// - Every other string becomes `s<length>`.
/// - A number up to 99 999 prints as itself; a larger one is a time when
///   plausible, and otherwise `n<digits>`.
///
enum PunctualPushShape {
    private static let largestPrinted = 99999.0

    /// Every word the capture's Punctual traffic uses (`findings.md` §47.1),
    /// plus BrowserChannel's `noop`, `stop` and `close`.
    static let vocabulary: Set<String> = [
        "availability", "c", "calendar", "close", "events", "group", "group-state-changes",
        "hub-web-ringing", "noop", "state", "stop", "typing", "user", "user-state-changes",
        "user-targeted-changes", "workflows"
    ]

    static func render(_ value: PBLiteValue, people: [String: String], now: Date) -> String {
        switch value {
        case .null:
            "null"
        case let .bool(flag):
            flag ? "true" : "false"
        case let .number(number):
            render(number: number, now: now)
        case let .string(text):
            render(string: text, people: people, now: now)
        case let .array(items):
            "[" + items.map { render($0, people: people, now: now) }.joined(separator: ",") + "]"
        case let .object(entries):
            "{" + entries.sorted { $0.key < $1.key }
                .map { key, value in
                    let rendered = render(value, people: people, now: now)
                    return render(string: key, people: people, now: now) + ":" + rendered
                }
                .joined(separator: ",") + "}"
        }
    }

    private static func render(number: PBLiteNumber, now: Date) -> String {
        let value: Double
        let digits: Int
        switch number {
        case let .integer(integer):
            value = Double(integer)
            digits = String(integer.magnitude).count
        case let .unsigned(unsigned):
            value = Double(unsigned)
            digits = String(unsigned).count
        case let .double(double):
            value = double
            digits = String(format: "%.0f", abs(double)).count
        }
        if abs(value) <= largestPrinted {
            if case let .double(double) = number, double != double.rounded() {
                return "\(double)"
            }
            return String(Int64(value))
        }
        return time(value, now: now) ?? "n\(digits)"
    }

    private static func render(string text: String, people: [String: String], now: Date) -> String {
        if let label = people[text] {
            return label
        }
        if let first = text.first, first == "[" || first == "{",
           let nested = try? PBLiteValue(json: Data(text.utf8)) {
            return "json(\(render(nested, people: people, now: now)))"
        }
        if !text.isEmpty, text.allSatisfy(\.isASCIIDigit) {
            // Five digits or fewer cannot be an id, and run 1 showed pushes
            // naming a watch by its sequence this way (`findings.md` §48).
            if text.count <= 5 {
                return "\"\(text)\""
            }
            return Double(text).flatMap { time($0, now: now) } ?? "d\(text.count)"
        }
        if vocabulary.contains(text) {
            return "\"\(text)\""
        }
        return isLowercaseWord(text) ? "w\(text.count)" : "s\(text.count)"
    }

    private static func isLowercaseWord(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars
            .allSatisfy { ("a" ... "z").contains($0) || $0 == "-" || $0 == "_" }
    }

    /// The same instant in each unit a time could be sent in, as the api
    /// probe's decoder judges it.
    private static func time(_ value: Double, now: Date) -> String? {
        let plausible = 978_307_200.0 ... 9_999_999_999.0
        let candidates = [value / 1_000_000, value / 1000, value]
        guard let seconds = candidates.first(where: plausible.contains) else { return nil }
        return "@" + APIProbeReport.relative(seconds - now.timeIntervalSince1970)
    }
}

private extension Character {
    var isASCIIDigit: Bool {
        ("0" ... "9").contains(self)
    }
}
