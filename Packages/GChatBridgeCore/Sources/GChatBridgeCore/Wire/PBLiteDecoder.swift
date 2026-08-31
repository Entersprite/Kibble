import Foundation
import SwiftProtobuf

/// Something the payload did that the schema did not expect.
///
/// This is the stand-in for upstream's `logger.warning`/`logger.debug` calls.
/// It is not error handling - decoding continues regardless - but the
/// information is worth keeping rather than discarding: an `.unknownField` issue
/// is precisely the signal upstream logs "to aid reverse-engineering the missing
/// field in the message" (pblite.py:110-111), and GChatBridgeCore may not import
/// a logging framework.
public struct PBLiteIssue: Hashable, Sendable, CustomStringConvertible {
    public enum Kind: Hashable, Sendable {
        /// The value handed to the decoder was not an array, so nothing was
        /// decoded (pblite.py:91-93).
        case notAnArray
        /// A field number the schema does not know. Google adds fields silently,
        /// so this is expected traffic, not a fault.
        case unknownField
        /// A singular field whose value could not be coerced. The field is left
        /// unset and decoding continues (pblite.py:40-45).
        case malformedScalar
        /// A repeated field with at least one uncoercible element. The whole
        /// field is cleared rather than left half-populated (pblite.py:69-70).
        case malformedRepeated
        /// A key in the trailing high-field-number dictionary was not an integer.
        case unparseableFieldNumberKey
        /// A `map<>` or `group` field. pblite cannot express either; googlechat
        /// .proto contains neither.
        case unrepresentableField
        /// Nesting exceeded the decoder's depth limit. No upstream counterpart:
        /// upstream recurses without a bound.
        case depthLimitExceeded
    }

    public let kind: Kind
    public let messageName: String
    /// `nil` only for `.notAnArray`, which is about the message, not a field.
    public let fieldNumber: Int?

    public var description: String {
        let field = fieldNumber.map { " field \($0)" } ?? ""
        return "\(messageName)\(field): \(kind)"
    }
}

/// Turns a pblite array into a `SwiftProtobuf.Message`.
///
/// The mechanism is SwiftProtobuf's own `Decoder`: the generated
/// `decodeMessage(decoder:)` asks for a field number and then calls back the
/// method for that field's declared type, which supplies the schema information
/// Python gets from runtime reflection. Two properties fall out of that for
/// free and match upstream exactly:
///
/// - An unknown field number hits the generated `switch`'s `default: break`, so
///   it is skipped rather than raised (pblite.py:108-121).
/// - Leaving an `inout` parameter untouched leaves the field unset, so a
///   malformed scalar costs one field and never the message (pblite.py:40-45).
///
/// **Never throws.** Decoding is permissive by design; every problem lands in
/// `Decoded.issues` instead.
///
/// Deviations from `maugclib/pblite.py`, all deliberate:
///
/// 1. A non-integral number (`12.5`) into an integer field leaves the field
///    unset. Upstream's `int(value)` would truncate it to `12`, and only for
///    `int64` - every other integer width would raise `TypeError` and drop the
///    field. Rejecting uniformly beats silently truncating.
/// 2. Every integer width accepts a JSON string, not just `int64`. Upstream
///    coerces `int64` alone and drops the rest; accepting them cannot lose
///    information and dropping them can.
/// 3. A repeated field whose value is not an array clears the field and records
///    an issue. Upstream would iterate a non-iterable and let the `TypeError`
///    escape `decode()` for message-typed repeated fields, aborting the whole
///    message - which contradicts its own documented contract.
/// 4. A nested message whose value is an empty array `[]` is *set* to an empty
///    message. Upstream leaves it unset, because reading a Python submessage
///    does not mark presence.
/// 5. `depthLimit` exists. Upstream recurses unbounded on attacker-controlled
///    input.
public enum PBLiteDecoder {
    public struct Decoded<M: SwiftProtobuf.Message>: Sendable {
        public let message: M
        public let issues: [PBLiteIssue]
    }

    public static let defaultDepthLimit = 64

    /// - Parameters:
    ///   - ignoreFirstItem: drop element 0 before anything else, so element 1
    ///     becomes field 1. Needed because the outer list of a response often
    ///     begins with an abbreviation of the message name (`cscmrp` for
    ///     `ClientSendChatMessageResponseP`) that is not part of the message
    ///     (pblite.py:79-82, 94-95).
    public static func decode<M: SwiftProtobuf.Message>(
        _ messageType: M.Type,
        from value: PBLiteValue,
        ignoreFirstItem: Bool = false,
        depthLimit: Int = defaultDepthLimit
    ) -> Decoded<M> {
        var source = PBLiteFieldSource(
            messageName: M.protoMessageName,
            value: value,
            ignoreFirstItem: ignoreFirstItem,
            depthLimit: depthLimit
        )
        var message = messageType.init()
        // No path in PBLiteFieldSource throws. `try?` is here because the
        // protocol is throwing, not because a failure is expected.
        try? message.decodeMessage(decoder: &source)
        source.flushUnconsumedField()
        return Decoded(message: message, issues: source.issues)
    }

    public static func decode<M: SwiftProtobuf.Message>(
        _ messageType: M.Type,
        fromJSON data: Data,
        ignoreFirstItem: Bool = false,
        depthLimit: Int = defaultDepthLimit
    ) throws -> Decoded<M> {
        try decode(
            messageType,
            from: PBLiteValue(json: data),
            ignoreFirstItem: ignoreFirstItem,
            depthLimit: depthLimit
        )
    }
}

/// The `(fieldNumber, value)` cursor that drives one message's decode.
struct PBLiteFieldSource {
    let messageName: String
    let depthLimit: Int
    var issues: [PBLiteIssue] = []

    private let fields: [(number: Int, value: PBLiteValue)]
    private var cursor = 0
    private var current: PBLiteValue = .null
    private var currentNumber = 0
    /// A field number was handed out and no `decode*Field` method has claimed it,
    /// which is how an unknown field number is detected: the generated `switch`
    /// silently falls through to `default: break` and calls nothing.
    private var awaitingConsumption = false

    init(messageName: String, value: PBLiteValue, ignoreFirstItem: Bool, depthLimit: Int) {
        self.messageName = messageName
        self.depthLimit = depthLimit
        guard case var .array(items) = value else {
            fields = []
            issues = [PBLiteIssue(kind: .notAnArray, messageName: messageName, fieldNumber: nil)]
            return
        }
        if ignoreFirstItem, !items.isEmpty {
            items.removeFirst()
        }
        var extras: [(number: Int, value: PBLiteValue)] = []
        var problems: [PBLiteIssue] = []
        // Rule 3: a trailing dictionary is an out-of-band {fieldNumber: value}
        // map for high field numbers, stripped from the positional list and
        // merged in afterwards (pblite.py:97-103). Sorted for determinism -
        // Swift dictionaries have no order, Python's preserve JSON key order.
        if let last = items.last, case let .object(entries) = last {
            items.removeLast()
            for (key, entry) in entries {
                if let number = Int(key) {
                    extras.append((number: number, value: entry))
                } else {
                    problems.append(
                        PBLiteIssue(
                            kind: .unparseableFieldNumberKey,
                            messageName: messageName,
                            fieldNumber: nil
                        )
                    )
                }
            }
            extras.sort { $0.number < $1.number }
        }
        // Rule 4: field numbers are 1-based positions - index 0 is field 1.
        fields = items.enumerated().map { (number: $0.offset + 1, value: $0.element) } + extras
        issues = problems
    }

    /// Called once after `decodeMessage` returns, because the final field's fate
    /// is only known after the loop has stopped asking for more.
    mutating func flushUnconsumedField() {
        guard awaitingConsumption else {
            return
        }
        awaitingConsumption = false
        // Upstream only logs an unknown field when the value is non-trivial
        // (pblite.py:114). A trailing `0`/`""`/`[]` is noise, not a discovery.
        if !current.isTrivial {
            record(.unknownField)
        }
    }

    /// Hands the current value to a `decode*Field` method, marking the field
    /// claimed. Every conformance method must route through this exactly once.
    mutating func take() -> PBLiteValue {
        awaitingConsumption = false
        return current
    }

    mutating func record(_ kind: PBLiteIssue.Kind) {
        issues.append(
            PBLiteIssue(kind: kind, messageName: messageName, fieldNumber: currentNumber)
        )
    }

    mutating func advance() -> Int? {
        flushUnconsumedField()
        while cursor < fields.count {
            let field = fields[cursor]
            cursor += 1
            // Rule 5: null means "field not present", so it is skipped entirely
            // and never reaches the schema (pblite.py:106-107).
            if field.value.isNull {
                continue
            }
            currentNumber = field.number
            current = field.value
            awaitingConsumption = true
            return field.number
        }
        return nil
    }

    /// Recurses into a nested message, folding its issues into ours.
    mutating func decodeNested<M: SwiftProtobuf.Message>(_ message: inout M, from value: PBLiteValue) {
        guard depthLimit > 0 else {
            record(.depthLimitExceeded)
            return
        }
        var nested = PBLiteFieldSource(
            messageName: M.protoMessageName,
            value: value,
            ignoreFirstItem: false,
            depthLimit: depthLimit - 1
        )
        try? message.decodeMessage(decoder: &nested)
        nested.flushUnconsumedField()
        issues += nested.issues
    }
}
