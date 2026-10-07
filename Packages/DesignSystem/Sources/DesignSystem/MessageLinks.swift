import ChatKit
import Foundation

/// Where a message's text links, and to what (links spec §7.2). Google's
/// anchored links come first, then anything `NSDataDetector` finds that
/// overlaps neither those nor a mention. Pure, so each rule is a test.
///
/// Ranges are `NSRange`, which counts UTF-16 code units, the unit the wire
/// uses (`findings.md` §41.1). A span that starts or ends off a `Character`
/// boundary is dropped, as `MentionHighlight` drops one: no link, never a
/// wrong one.
public enum MessageLinks {
    public struct Span: Equatable, Sendable {
        public let range: NSRange
        public let url: URL
    }

    public static func spans(in text: String, links: [MessageLink], avoiding taken: [NSRange]) -> [Span] {
        var occupied = taken
        var spans: [Span] = []
        for link in links {
            guard let start = link.start, let length = link.length, LinkPolicy.canOpen(link.url),
                  let range = characterAligned(start: start, length: length, in: text),
                  !overlaps(range, occupied)
            else { continue }
            spans.append(Span(range: range, url: link.url))
            occupied.append(range)
        }
        for (range, url) in detected(in: text) where LinkPolicy.canOpen(url) && !overlaps(range, occupied) {
            spans.append(Span(range: range, url: url))
            occupied.append(range)
        }
        return spans.sorted { $0.range.location < $1.range.location }
    }

    private static func characterAligned(start: Int, length: Int, in text: String) -> NSRange? {
        let units = text.utf16
        guard start >= 0, length > 0, length <= units.count - start,
              String.Index(units.index(units.startIndex, offsetBy: start), within: text) != nil,
              String.Index(units.index(units.startIndex, offsetBy: start + length), within: text) != nil
        else { return nil }
        return NSRange(location: start, length: length)
    }

    private static func overlaps(_ range: NSRange, _ others: [NSRange]) -> Bool {
        others.contains { NSIntersectionRange($0, range).length > 0 }
    }

    private static func detected(in text: String) -> [(NSRange, URL)] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return [] }
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            match.url.map { (match.range, $0) }
        }
    }
}
