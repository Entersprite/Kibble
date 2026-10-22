import ChatKit
import Foundation

/// Internal URLs become separate quotes. Text offsets are transformed only
/// for rendering; the original message remains the menu/send authority.
struct MessageLinkPresentation {
    let message: Message
    let references: [MessageLink]

    init(_ original: Message, internalHosts: Set<String>) {
        let links = Self.links(in: original, internalHosts: internalHosts)
        let internalLinks = links.filter {
            $0.messageAddress != nil || internalHosts.contains($0.url.host()?.lowercased() ?? "")
        }
        let removed = Self.removedRanges(in: original.text, links: internalLinks)
        message = Self.removing(removed, from: original, links: links, internalHosts: internalHosts)
        var seen: Set<URL> = []
        references = internalLinks.filter { seen.insert($0.url).inserted }
    }

    private static func links(in original: Message, internalHosts: Set<String>) -> [MessageLink] {
        var links = original.links
        if original.text.contains("://"), internalHosts.contains(where: {
            original.text.range(of: $0, options: .caseInsensitive) != nil
        }),
            let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            for match in detector.matches(
                in: original.text,
                range: NSRange(original.text.startIndex..., in: original.text)
            ) {
                guard let url = match.url, internalHosts.contains(url.host()?.lowercased() ?? ""),
                      !links
                      .contains(where: { $0.start == match.range.location && $0.length == match.range.length
                      })
                else { continue }
                links.append(MessageLink(url: url, start: match.range.location, length: match.range.length))
            }
        }
        return links
    }

    private static func removedRanges(in text: String, links: [MessageLink]) -> [NSRange] {
        var removed: [NSRange] = []
        for link in links {
            guard let start = link.start, let length = link.length,
                  let range = MessageFormat(style: "", start: start, length: length).range(in: text)
            else { continue }
            let span = NSRange(range, in: text)
            if !removed.contains(where: { NSIntersectionRange($0, span).length > 0 }) {
                removed.append(span)
            }
        }
        return removed.sorted { $0.location < $1.location }
    }

    private static func removing(
        _ removed: [NSRange], from original: Message, links: [MessageLink], internalHosts: Set<String>
    ) -> Message {
        var result = original
        for span in removed.reversed() {
            if let range = Range(span, in: result.text) {
                result.text.removeSubrange(range)
            }
        }
        result.mentions = original.mentions.compactMap { mention in
            guard !Self.overlaps(mention.start, mention.length, removed) else { return nil }
            var mention = mention
            mention.start = Self.offset(mention.start, after: removed)
            return mention
        }
        result.content?.formatting = (original.content?.formatting ?? []).compactMap { format in
            guard format.range(in: original.text) != nil else { return nil }
            let start = Self.offset(format.start, after: removed)
            let end = Self.offset(format.start + format.length, after: removed)
            return end > start ? MessageFormat(style: format.style, start: start, length: end - start) : nil
        }
        result.content?.customEmoji = (original.content?.customEmoji ?? []).compactMap { span in
            guard span.range(in: original.text) != nil,
                  !Self.overlaps(span.start, span.length, removed) else { return nil }
            var span = span
            span.start = Self.offset(span.start, after: removed)
            return span
        }
        result.links = links.compactMap { link in
            guard link.messageAddress == nil, !internalHosts.contains(link.url.host()?.lowercased() ?? "")
            else { return nil }
            var link = link
            if let start = link.start, let length = link.length {
                guard !Self.overlaps(start, length, removed) else { return nil }
                link.start = Self.offset(start, after: removed)
            }
            return link
        }
        return result
    }

    private static func overlaps(_ start: Int, _ length: Int, _ ranges: [NSRange]) -> Bool {
        guard start >= 0, length > 0, start <= Int.max - length else { return true }
        return ranges
            .contains { NSIntersectionRange(NSRange(location: start, length: length), $0).length > 0 }
    }

    private static func offset(_ value: Int, after ranges: [NSRange]) -> Int {
        value - ranges.reduce(0) { $0 + max(0, min(value - $1.location, $1.length)) }
    }
}
