import Foundation
import SwiftProtobuf

/// A scalar pblite can carry, and how to coerce one out of a JSON value.
///
/// This is where upstream's per-type special cases live (pblite.py:31-37):
/// `bytes` arrives base64-encoded, integers arrive as JSON strings *or* numbers,
/// and everything else is taken as-is - so a number in a `string` field is a
/// type mismatch, not something to stringify.
protocol PBLiteScalar {
    init?(pblite: PBLiteValue)
}

extension PBLiteScalar where Self: FixedWidthInteger {
    init?(pblite: PBLiteValue) {
        switch pblite {
        case let .number(number):
            guard let value: Self = number.exactInteger() else {
                return nil
            }
            self = value
        case let .string(text):
            guard let value = Self(text, radix: 10) else {
                return nil
            }
            self = value
        default:
            return nil
        }
    }
}

extension PBLiteScalar where Self: BinaryFloatingPoint {
    init?(pblite: PBLiteValue) {
        guard case let .number(number) = pblite else {
            return nil
        }
        self = Self(number.doubleValue)
    }
}

extension Int: PBLiteScalar {}
extension Int32: PBLiteScalar {}
extension Int64: PBLiteScalar {}
extension UInt32: PBLiteScalar {}
extension UInt64: PBLiteScalar {}
extension Float: PBLiteScalar {}
extension Double: PBLiteScalar {}

extension Bool: PBLiteScalar {
    /// A JSON number is accepted because Python's bools *are* ints, so upstream's
    /// `setattr` takes `0`/`1` for a bool field without complaint.
    init?(pblite: PBLiteValue) {
        switch pblite {
        case let .bool(value):
            self = value
        case let .number(number):
            self = number.doubleValue != 0
        default:
            return nil
        }
    }
}

extension String: PBLiteScalar {
    init?(pblite: PBLiteValue) {
        guard case let .string(value) = pblite else {
            return nil
        }
        self = value
    }
}

extension Data: PBLiteScalar {
    /// Strict base64: Foundation rejects stray non-alphabet characters where
    /// Python's `b64decode` would discard them. Rejecting leaves the field unset,
    /// which is the safer of the two failures.
    init?(pblite: PBLiteValue) {
        guard case let .string(text) = pblite, let decoded = Data(base64Encoded: text) else {
            return nil
        }
        self = decoded
    }
}

// MARK: - Coercion helpers

extension PBLiteFieldSource {
    mutating func nextScalar<T: PBLiteScalar>(_: T.Type) -> T? {
        guard let value = T(pblite: take()) else {
            record(.malformedScalar)
            return nil
        }
        return value
    }

    mutating func single<T: PBLiteScalar>(_ target: inout T) {
        guard let value = nextScalar(T.self) else {
            return
        }
        target = value
    }

    mutating func single<T: PBLiteScalar>(_ target: inout T?) {
        guard let value = nextScalar(T.self) else {
            return
        }
        target = value
    }

    /// Rule 9: one bad element clears the whole field rather than leaving it
    /// half-populated (pblite.py:69-70). Values already present are cleared too,
    /// matching upstream's `ClearField`.
    mutating func repeated<T: PBLiteScalar>(_ target: inout [T]) {
        guard case let .array(items) = take() else {
            target = []
            record(.malformedRepeated)
            return
        }
        var decoded: [T] = []
        for item in items {
            guard let value = T(pblite: item) else {
                target = []
                record(.malformedRepeated)
                return
            }
            decoded.append(value)
        }
        target += decoded
    }

    mutating func nextEnum<E: Enum>() -> E? where E.RawValue == Int {
        guard let raw = Int(pblite: take()), let value = E(rawValue: raw) else {
            record(.malformedScalar)
            return nil
        }
        return value
    }

    mutating func unrepresentable() {
        _ = take()
        record(.unrepresentableField)
    }
}
