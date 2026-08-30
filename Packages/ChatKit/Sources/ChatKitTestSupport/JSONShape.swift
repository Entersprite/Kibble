import Foundation

/// Describes the *structure* of an API response without revealing its content.
///
/// Built for diagnosing "why is this field nil" questions against real
/// accounts. The answer needs key presence and value types, never message text,
/// names or email addresses — so every string value is replaced by its type and
/// length, and only an allowlist of structural fields (enums such as `HUMAN` or
/// `JOINED`) keeps its value.
///
/// Output is safe to share.
public enum JSONShape {
    /// Fields whose values are enum-like and carry no user content.
    public static let structuralKeys: Set<String> = [
        "type", "state", "role", "affiliation", "deletionType",
        "spaceType", "spaceThreadingState", "spaceHistoryState",
        "singleUserBotDm", "threadReply", "importMode", "externalUserAllowed",
        "isAnonymous", "sortOrder",
    ]

    public static func describe(
        _ data: Data,
        structuralKeys: Set<String> = JSONShape.structuralKeys
    ) -> String {
        guard let parsed = try? JSONSerialization.jsonObject(with: data) else {
            return "(response could not be parsed as JSON; \(data.count) bytes)"
        }
        var context = Context(structuralKeys: structuralKeys)
        render(parsed, key: nil, indent: 0, context: &context)
        return context.lines.joined(separator: "\n")
    }

    /// Accumulates output and carries the allowlist, so the recursive helpers
    /// stay short.
    private struct Context {
        let structuralKeys: Set<String>
        var lines: [String] = []

        mutating func emit(_ text: String, indent: Int) {
            lines.append(String(repeating: "  ", count: indent) + text)
        }
    }

    private static func render(_ value: Any, key: String?, indent: Int, context: inout Context) {
        let label = key.map { "\($0): " } ?? ""

        switch value {
        case let dictionary as [String: Any]:
            renderObject(dictionary, label: label, indent: indent, context: &context)
        case let array as [Any]:
            renderArray(array, label: label, indent: indent, context: &context)
        default:
            renderScalar(value, key: key, label: label, indent: indent, context: &context)
        }
    }

    private static func renderObject(
        _ dictionary: [String: Any],
        label: String,
        indent: Int,
        context: inout Context
    ) {
        context.emit("\(label){", indent: indent)
        for childKey in dictionary.keys.sorted() {
            render(dictionary[childKey] as Any, key: childKey, indent: indent + 1, context: &context)
        }
        context.emit("}", indent: indent)
    }

    private static func renderArray(
        _ array: [Any],
        label: String,
        indent: Int,
        context: inout Context
    ) {
        guard !array.isEmpty else {
            context.emit("\(label)[empty array]", indent: indent)
            return
        }
        context.emit("\(label)[\(array.count) items]", indent: indent)
        if let objects = array as? [[String: Any]] {
            renderMerged(objects, key: nil, indent: indent + 1, context: &context)
        } else {
            render(array[0], key: nil, indent: indent + 1, context: &context)
        }
    }

    private static func renderScalar(
        _ value: Any,
        key: String?,
        label: String,
        indent: Int,
        context: inout Context
    ) {
        let isStructural = key.map { context.structuralKeys.contains($0) } ?? false

        switch value {
        case let string as String:
            let rendered = isStructural ? "\"\(string)\"" : "string(\(string.count) chars)"
            context.emit("\(label)\(rendered)", indent: indent)
        case let number as NSNumber:
            context.emit("\(label)\(describe(number, isStructural: isStructural))", indent: indent)
        default:
            context.emit("\(label)null", indent: indent)
        }
    }

    private static func describe(_ number: NSNumber, isStructural: Bool) -> String {
        if isStructural { return "\(number)" }
        return CFGetTypeID(number) == CFBooleanGetTypeID() ? "bool" : "number"
    }

    /// Merges the keys of a collection of objects so a field present on only
    /// some of them is visible — the usual reason a value looks unexpectedly
    /// nil. Recurses, because the interesting difference is often nested (a
    /// `displayName` inside a `member` inside a `memberships` array).
    private static func renderMerged(
        _ objects: [[String: Any]],
        key: String?,
        indent: Int,
        context: inout Context
    ) {
        let label = key.map { "\($0): " } ?? ""
        context.emit("\(label){ merged from \(objects.count)", indent: indent)

        var presence: [String: Int] = [:]
        for object in objects {
            for objectKey in object.keys { presence[objectKey, default: 0] += 1 }
        }

        for objectKey in presence.keys.sorted() {
            renderMergedValue(
                for: objectKey,
                in: objects,
                indent: indent,
                context: &context
            )
        }

        context.emit("}", indent: indent)
    }

    private static func renderMergedValue(
        for key: String,
        in objects: [[String: Any]],
        indent: Int,
        context: inout Context
    ) {
        let values = objects.compactMap { $0[key] }
        guard let sample = values.first else { return }
        let suffix =
            values.count == objects.count
            ? ""
            : "  <- only \(values.count)/\(objects.count)"

        if let dictionaries = values as? [[String: Any]] {
            appendWithSuffix(suffix, into: &context) { inner in
                renderMerged(dictionaries, key: key, indent: indent + 1, context: &inner)
            }
        } else if let nestedArrays = values as? [[Any]] {
            let flattened = nestedArrays.flatMap { $0 }
            context.emit("\(key): [\(flattened.count) items]\(suffix)", indent: indent + 1)
            if let dictionaries = flattened as? [[String: Any]], !dictionaries.isEmpty {
                renderMerged(dictionaries, key: nil, indent: indent + 2, context: &context)
            }
        } else {
            appendWithSuffix(suffix, into: &context) { inner in
                render(sample, key: key, indent: indent + 1, context: &inner)
            }
        }
    }

    /// Renders into a scratch context so the presence suffix can be attached to
    /// the first emitted line.
    private static func appendWithSuffix(
        _ suffix: String,
        into context: inout Context,
        body: (inout Context) -> Void
    ) {
        var scratch = Context(structuralKeys: context.structuralKeys)
        body(&scratch)
        if !scratch.lines.isEmpty, !suffix.isEmpty {
            scratch.lines[0] += suffix
        }
        context.lines.append(contentsOf: scratch.lines)
    }
}
