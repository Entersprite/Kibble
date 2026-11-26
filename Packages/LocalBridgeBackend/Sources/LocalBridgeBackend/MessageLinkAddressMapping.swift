import ChatKit
import Foundation

/// Provider URL syntax stays beside its opaque identifier construction.
enum MessageLinkAddressMapping {
    static func address(_ url: URL) -> MessageAddress? {
        guard url.scheme?.lowercased() == "https", url.host()?.lowercased() == "chat.google.com",
              url.user == nil, url.password == nil, url.port == nil || url.port == 443 else { return nil }
        var parts = url.pathComponents.filter { $0 != "/" }
        if parts.count >= 2, parts[0] == "u", Int(parts[1]) != nil {
            parts.removeFirst(2)
        }
        guard parts.count == 2 || parts.count == 4,
              parts[0] == "room" || parts[0] == "dm",
              parts.dropFirst().allSatisfy(validIdentifier) else { return nil }
        return MessageAddress(
            conversation: Conversation.ID("\(parts[0] == "room" ? "space" : "dm")/\(parts[1])"),
            thread: parts.count == 4 ? MessageThread.ID(parts[2]) : nil,
            message: parts.count == 4 ? Message.ID(parts[3]) : nil
        )
    }

    private static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 && value.utf8.allSatisfy {
            (48 ... 57).contains($0) || (65 ... 90).contains($0) || (97 ... 122).contains($0)
                || $0 == 45 || $0 == 95
        }
    }

    static func addingAddresses(to links: [MessageLink], in text: String) -> [MessageLink] {
        var result = links.map { link in
            var link = link
            link.messageAddress = address(link.url)
            return link
        }
        // URL annotations normally carry spans. Older provider bodies can
        // omit them; detect only this provider's own addresses in that case.
        guard text.lowercased().contains("https://chat.google.com/"),
              let expression = try? NSRegularExpression(
                  pattern: "https://chat\\.google\\.com/[^\\s<>]+", options: [.caseInsensitive]
              )
        else { return result }
        for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            let raw = String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?)]}"))
            let span = NSRange(location: match.range.location, length: raw.utf16.count)
            guard let url = URL(string: raw),
                  let address = address(url),
                  !result
                  .contains(where: { $0.start == span.location && $0.length == span.length })
            else { continue }
            result.append(MessageLink(
                url: url, start: span.location, length: span.length, messageAddress: address
            ))
        }
        return result
    }
}
