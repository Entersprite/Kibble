import Foundation
import GChatBridgeCore

/// What `list_topics` pages carry in the way of annotations - counts only,
/// never text, ids or names (the report is pasted into `findings.md`).
/// Settles the mentions spec's two `[Verify]`s: whether annotations arrive
/// at all, and which unit a span counts in - the second only when
/// `discriminating` is non-zero (a span at offset 0 lands on "@" under
/// every reading and says nothing about the unit).
struct MentionShapes: Equatable {
    var messages = 0
    var withAnnotations = 0
    /// `AnnotationType` raw value → count. The typed value when `hasType`,
    /// otherwise the raw field-1 varints from `unknownFields` - the same
    /// "believe the walk" rule `mentionKinds` follows, one level up.
    var annotationTypes: [Int: Int] = [:]
    /// `USER_MENTION` annotations, however malformed.
    var userMentions = 0
    /// `UserMentionMetadata.TypeEnum` raw value → count, `hasType` only.
    var mentionKinds: [Int: Int] = [:]
    /// `USER_MENTION` whose metadata `hasType` is false …
    var mentionKindsAbsent = 0
    /// … and the raw field-2 varints found in its `unknownFields`.
    var mentionKindsRaw: [Int: Int] = [:]
    /// `USER_MENTION` whose `metadata` oneof is not `user_mention_metadata` -
    /// unset, or another case. Kept out of `mentionKindsAbsent`, because
    /// `annotation.userMentionMetadata` would hand back a default value whose
    /// `hasType` is false and make "no metadata" read as "kind absent".
    var metadataAbsent = 0
    /// `ChannelEventMapping.mentions(_:)` output, summed.
    var mapped = 0
    /// `USER_MENTION` annotations with a start and a length …
    var spans = 0
    /// … whose start + length fits `text.utf16`.
    var spansInRange = 0
    /// … whose UTF-16 offset lands on "@".
    var spansAtUTF16 = 0
    /// … whose Unicode-scalar offset lands on "@".
    var spansAtScalar = 0
    /// … whose Character offset lands on "@".
    var spansAtCharacter = 0
    /// … where the three readings do not all name the same index **and** at
    /// least one lands on "@". A span that is "@" under no reading (out of
    /// range, negative, or simply elsewhere) says nothing about the unit, so
    /// it is not counted here even though its readings disagree.
    var discriminating = 0
}

/// The probe's mentions section. Split into its own file for the same
/// `file_length` reason `APIProbeReport+History.swift` is.
///
/// Both functions are pure, so `MentionShapesTests` covers every count
/// against invented messages. Nothing either returns can carry a message's
/// text, a user id or a name: every value is a count or an enum raw value.
extension APIProbeReport {
    /// `AnnotationType`'s field number inside `Annotation`, read from
    /// `unknownFields` only when the typed decode rejected the value.
    private static let annotationTypeField = 1

    /// `UserMentionMetadata.type`'s field number, likewise.
    private static let mentionKindField = 2

    static func mentionShapes(_ messages: [GChatBridgeCore.Message]) -> MentionShapes {
        var shapes = MentionShapes()
        for message in messages {
            shapes.messages += 1
            guard !message.annotations.isEmpty else { continue }
            shapes.withAnnotations += 1
            shapes.mapped += ChannelEventMapping.mentions(message.annotations).count
            for annotation in message.annotations {
                countType(of: annotation, into: &shapes)
                guard annotation.hasType, annotation.type == .userMention else { continue }
                shapes.userMentions += 1
                if case let .userMentionMetadata(metadata)? = annotation.metadata {
                    countKind(of: metadata, into: &shapes)
                } else {
                    shapes.metadataAbsent += 1
                }
                if annotation.hasStartIndex, annotation.hasLength {
                    countSpan(
                        start: Int(annotation.startIndex),
                        length: Int(annotation.length),
                        in: message.textBody,
                        into: &shapes
                    )
                }
            }
        }
        return shapes
    }

    static func mentionShapesLines(_ shapes: MentionShapes) -> [String] {
        let spans = shapes.spans
        return [
            "  messages with annotations: \(shapes.withAnnotations)/\(shapes.messages)",
            "  annotation types: \(tally(shapes.annotationTypes))",
            "  mention kinds: \(tally(shapes.mentionKinds)); "
                + "presence absent \(shapes.mentionKindsAbsent) (raw: \(tally(shapes.mentionKindsRaw))); "
                + "no metadata \(shapes.metadataAbsent)",
            "  USER_MENTION annotations: \(shapes.userMentions), mapped to mentions: \(shapes.mapped)",
            "  mention spans: \(spans), in range (UTF-16) \(shapes.spansInRange); "
                + "on \"@\": UTF-16 \(shapes.spansAtUTF16)/\(spans), "
                + "scalar \(shapes.spansAtScalar)/\(spans), "
                + "Character \(shapes.spansAtCharacter)/\(spans); "
                + "discriminating \(shapes.discriminating)"
        ]
    }

    private static func countType(
        of annotation: GChatBridgeCore.Annotation,
        into shapes: inout MentionShapes
    ) {
        if annotation.hasType {
            shapes.annotationTypes[annotation.type.rawValue, default: 0] += 1
            return
        }
        for raw in ProtoFieldScan.varintValues(
            ofField: annotationTypeField,
            in: annotation.unknownFields.data
        ) {
            shapes.annotationTypes[Int(clamping: raw), default: 0] += 1
        }
    }

    /// **Never reads `metadata.type` without `hasType`.** A kind outside the
    /// vendored proto2 enum clears the presence bit and would otherwise count
    /// as `0` (`unspecified`) - the trap `CLAUDE.md`'s typed-decode rule names.
    private static func countKind(of metadata: UserMentionMetadata, into shapes: inout MentionShapes) {
        guard metadata.hasType else {
            shapes.mentionKindsAbsent += 1
            for raw in ProtoFieldScan.varintValues(
                ofField: mentionKindField,
                in: metadata.unknownFields.data
            ) {
                shapes.mentionKindsRaw[Int(clamping: raw), default: 0] += 1
            }
            return
        }
        shapes.mentionKinds[metadata.type.rawValue, default: 0] += 1
    }

    private static func countSpan(
        start: Int,
        length: Int,
        in text: String,
        into shapes: inout MentionShapes
    ) {
        shapes.spans += 1
        if start >= 0, length >= 0, start + length <= text.utf16.count {
            shapes.spansInRange += 1
        }
        let byUTF16 = utf16Index(start, in: text)
        let byScalar = scalarIndex(start, in: text)
        let byCharacter = characterIndex(start, in: text)
        let atUTF16 = byUTF16.map { text[$0] == "@" } ?? false
        let atScalar = byScalar.map { text.unicodeScalars[$0] == "@" } ?? false
        let atCharacter = byCharacter.map { text[$0] == "@" } ?? false
        if atUTF16 {
            shapes.spansAtUTF16 += 1
        }
        if atScalar {
            shapes.spansAtScalar += 1
        }
        if atCharacter {
            shapes.spansAtCharacter += 1
        }
        // A reading that resolves to no index differs from one that does.
        // Three nils "agree", but then nothing lands on "@" either - and
        // disagreement alone names no unit, so one reading must land there.
        let allAgree = byUTF16 == byScalar && byScalar == byCharacter
        if !allAgree, atUTF16 || atScalar || atCharacter {
            shapes.discriminating += 1
        }
    }

    /// `nil` when out of range, or when the offset falls inside a Character
    /// (`String.Index(_:within:)` fails there) - "@" is always a Character
    /// of its own, so a mid-Character offset cannot be the one that names it.
    private static func utf16Index(_ offset: Int, in text: String) -> String.Index? {
        guard offset >= 0, offset < text.utf16.count else { return nil }
        return String.Index(text.utf16.index(text.utf16.startIndex, offsetBy: offset), within: text)
    }

    private static func scalarIndex(_ offset: Int, in text: String) -> String.Index? {
        guard offset >= 0, offset < text.unicodeScalars.count else { return nil }
        return text.unicodeScalars.index(text.unicodeScalars.startIndex, offsetBy: offset)
    }

    private static func characterIndex(_ offset: Int, in text: String) -> String.Index? {
        guard offset >= 0, offset < text.count else { return nil }
        return text.index(text.startIndex, offsetBy: offset)
    }

    /// `raw×count` pairs, keys ascending; `none` when empty.
    private static func tally(_ counts: [Int: Int]) -> String {
        guard !counts.isEmpty else { return "none" }
        return counts.sorted { $0.key < $1.key }
            .map { "\($0.key)×\($0.value)" }
            .joined(separator: " ")
    }
}
