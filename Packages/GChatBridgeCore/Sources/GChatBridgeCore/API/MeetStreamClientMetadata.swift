import Foundation

/// Only the public application kind/version from a current hc:cc shell
/// configuration. Never copy its account fields, logging IDs or capabilities.
enum MeetStreamClientMetadata {
    static func extract(_ html: Data) -> (application: UInt64, version: String)? {
        guard html.count <= 2_000_000, let text = String(data: html, encoding: .utf8),
              let regex = try? NSRegularExpression(pattern: #"\[\s*"hc:cc"\s*,"#) else { return nil }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard matches.count == 1, let match = matches.first, let range = Range(match.range, in: text),
              let array = jsonArray(text[range.lowerBound...]),
              let value = try? PBLiteValue(json: Data(array.utf8)), let fields = value.arrayValue,
              fields.count > 6, case let .number(kind) = fields[1],
              let application: UInt64 = kind.exactInteger(), application <= UInt64(Int32.max),
              let version = fields[6].stringValue, !version.isEmpty, version.utf8.count <= 128,
              version.utf8.allSatisfy({ (33 ... 126).contains($0) }) else { return nil }
        return (application, version)
    }

    private static func jsonArray(_ text: Substring) -> String? {
        var depth = 0
        var quoted = false
        var escaped = false
        var count = 0
        for index in text.indices {
            count += 1
            guard count <= 500_000 else { return nil }
            let char = text[index]
            if quoted {
                if escaped {
                    escaped = false
                } else if char == "\\" {
                    escaped = true
                } else if char == "\"" {
                    quoted = false
                }
            } else if char == "\"" {
                quoted = true
            } else if char == "[" {
                depth += 1
            } else if char == "]" {
                depth -= 1
                if depth == 0 {
                    return String(text[...index])
                }
            }
        }
        return nil
    }
}
