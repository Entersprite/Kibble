import Foundation

/// Where Chat on the web keeps its PeopleStack key: a literal in its own
/// JavaScript, not the page's WIZ data (`findings.md` §62.4). Found at run
/// time and never written down, because the repository is public.
public enum PeopleStackKey {
    /// The module whose config literal holds it, in the build of 2026-10-06.
    public static let configModule = "F41ord"

    /// The address of one module of the page's own build: the page's bundle
    /// address with its module lists replaced. `nil` when the page names no
    /// bundle.
    ///
    /// The address is read out to its delimiters whether it sits in an
    /// attribute or, JSON-escaped, in a script.
    public static func moduleURL(inPage page: String, module: String, origin: String) -> URL? {
        let text = page.replacingOccurrences(of: "\\/", with: "/")
            .replacingOccurrences(of: "\\u003d", with: "=")
            .replacingOccurrences(of: "\\u003D", with: "=")
        guard let marker = text.range(of: "/_/js/k=boq-dynamite") else { return nil }
        let delimiters: Set<Character> = ["\"", "'", " ", "<", ">", "(", ")", "\\"]
        var start = marker.lowerBound
        while start > text.startIndex, !delimiters.contains(text[text.index(before: start)]) {
            start = text.index(before: start)
        }
        var end = marker.upperBound
        while end < text.endIndex, !delimiters.contains(text[end]) {
            end = text.index(after: end)
        }
        var address = String(text[start ..< end])
        if address.hasPrefix("//") {
            address = "https:" + address
        } else if address.hasPrefix("/") {
            address = origin + address
        }
        guard address.hasPrefix("https://"), let split = address.range(of: "/_/js/") else { return nil }
        let kept = address[split.upperBound...].split(separator: "/").filter { segment in
            !["m=", "exm=", "excm="].contains { segment.hasPrefix($0) }
        }
        return URL(string: address[..<split.upperBound] + (kept + ["m=\(module)"]).joined(separator: "/"))
    }

    /// Every distinct Google API key literal in `bundle`, the one in the
    /// config's `[null,null,<dev key>,<key>]` first.
    public static func candidates(inBundle bundle: String) -> [String] {
        var found = configKey(inBundle: bundle).map { [$0] } ?? []
        let any = "(?<![0-9A-Za-z_-])(" + keyPattern + ")(?![0-9A-Za-z_-])"
        for match in matches(of: any, in: bundle) where !found.contains(match) {
            found.append(match)
        }
        return found
    }

    /// The key in the config's `[null,null,<dev key>,<key>]`, if the bundle
    /// has that literal.
    public static func configKey(inBundle bundle: String) -> String? {
        matches(of: #"\[null,null,["'][^"']{39}["'],["']("# + keyPattern + #")["']\]"#, in: bundle).first
    }

    private static let keyPattern = "AIza[0-9A-Za-z_-]{35}"

    /// Capture group 1 of every match.
    private static func matches(of pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let whole = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: whole).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
    }
}
