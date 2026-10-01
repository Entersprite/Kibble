import Foundation

/// The shape of a `get_projector_config` answer (`findings.md` §52.2), masked
/// by parsing, never by pattern (`CLAUDE.md`): the whole body is decoded as
/// JSON and walked, and nothing from inside a value is printed.
///
/// - A string becomes `s<length>`, unless it is an `https` URL, which becomes
///   its host (as `APIProbeReport.renderHost` prints one), its first path
///   segment when that is a plain lowercase word, and the names of its query
///   parameters - the parts that say which endpoint the viewer uses.
/// - A number up to 99 prints (an enum or a count); a larger one is
///   `n<digits>`.
/// - An object key prints when it is an identifier; any other is `k<length>`.
enum ProjectorConfigShape {
    private static let maxDepth = 8
    private static let maxElements = 20

    static func render(_ body: Data) -> String {
        var data = body
        // Google's XSSI guard, when present: `)]}'` and a newline.
        if let text = String(data: body, encoding: .utf8), text.hasPrefix(")]}'") {
            data = Data(text.drop { $0 != "\n" }.dropFirst().utf8)
        }
        guard let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return "not JSON (\(body.count) bytes)"
        }
        return render(value, depth: 0)
    }

    private static func render(_ value: Any, depth: Int) -> String {
        guard depth < maxDepth else { return "…" }
        switch value {
        case let array as [Any]:
            var parts = array.prefix(maxElements).map { render($0, depth: depth + 1) }
            if array.count > maxElements {
                parts.append("…+\(array.count - maxElements)")
            }
            return "[" + parts.joined(separator: ",") + "]"
        case let object as [String: Any]:
            let parts = object.keys.sorted().map { key in
                "\(isIdentifier(key) ? key : "k\(key.count)"):\(render(object[key] as Any, depth: depth + 1))"
            }
            return "{" + parts.joined(separator: ",") + "}"
        case let text as String:
            return url(text) ?? "s\(text.count)"
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            let digits = number.stringValue
            if let small = Int(digits), (0 ... 99).contains(small) {
                return digits
            }
            return "n\(digits.count)"
        case is NSNull:
            return "null"
        default:
            return "?"
        }
    }

    private static func url(_ text: String) -> String? {
        guard text.hasPrefix("https://"), let components = URLComponents(string: text),
              let host = components.host
        else { return nil }
        let segments = components.path.split(separator: "/")
        var path = ""
        if let first = segments.first {
            path = isPlainWord(first) ? "/\(first)" : "/…"
            if segments.count > 1 {
                path += "/…"
            }
        }
        let names = (components.queryItems ?? []).map { isIdentifier($0.name) ? $0.name : "?" }
        return "url(\(APIProbeReport.renderHost(host.lowercased())) \(path.isEmpty ? "/" : path) "
            + "?\(names.isEmpty ? "-" : names.joined(separator: ",")))"
    }

    private static func isPlainWord(_ text: some StringProtocol) -> Bool {
        !text.isEmpty && text.count <= 30 && text.allSatisfy { $0.isASCII && $0.isLowercase && $0.isLetter }
    }

    private static func isIdentifier(_ text: String) -> Bool {
        guard let first = text.first, first.isASCII, first.isLetter || first == "_", text.count <= 40
        else { return false }
        return text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
    }
}
