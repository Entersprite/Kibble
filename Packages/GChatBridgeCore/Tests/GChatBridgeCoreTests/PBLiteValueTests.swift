import Foundation
import Testing
@testable import GChatBridgeCore

/// `PBLiteValue` is the boundary between JSON bytes and the protobuf codec, so
/// the properties pinned here are the ones the codec silently relies on: gaps
/// survive, 64-bit ids survive, and a tree stays equal to itself across a
/// serialise/parse cycle.
@Suite("pblite value")
struct PBLiteValueTests {
    @Test("a JSON array with gaps round-trips with every null in place")
    func gapsSurviveJSON() throws {
        let tree: PBLiteValue = ["s", nil, nil, nil, nil, 7]
        let json = try tree.jsonString()
        #expect(json == #"["s",null,null,null,null,7]"#)
        #expect(try PBLiteValue(json: Data(json.utf8)) == tree)
    }

    /// The reason `.number` is not a bare `Double`: this id needs 63 bits and a
    /// binary64 has 53 of mantissa, so a Double pipeline would quietly return
    /// 9223372036854775807 as 9223372036854775808.
    @Test("a 64-bit id survives JSON without losing a digit")
    func bigIntegerPrecision() throws {
        let tree: PBLiteValue = .array([.number(.integer(9_223_372_036_854_775_807))])
        let json = try tree.jsonString()
        #expect(json == "[9223372036854775807]")
        let parsed = try PBLiteValue(json: Data(json.utf8))
        #expect(parsed == tree)
        #expect(parsed.arrayValue?.first == .number(.integer(9_223_372_036_854_775_807)))
    }

    @Test("numeric equality ignores which representation a number arrived in")
    func numberEqualityIsNumeric() {
        #expect(PBLiteNumber.integer(1) == .double(1.0))
        #expect(PBLiteNumber.integer(1) == .unsigned(1))
        #expect(PBLiteNumber.integer(1) != .double(1.5))
        #expect(Set([PBLiteNumber.integer(1), .double(1.0), .unsigned(1)]).count == 1)
    }

    @Test("true does not decode as 1, and 1 does not decode as true")
    func boolAndNumberStayDistinct() throws {
        #expect(try PBLiteValue(json: Data("[true,1]".utf8)) == .array([.bool(true), 1]))
    }

    @Test("a trailing high-field-number dictionary parses as an object node")
    func objectNodeParses() throws {
        let parsed = try PBLiteValue(json: Data(#"["s",{"100":"12345"}]"#.utf8))
        #expect(parsed == .array([.string("s"), .object(["100": .string("12345")])]))
    }

    @Test("null is a value, not an absence")
    func nullIsAValue() throws {
        #expect(PBLiteValue.null.isNull)
        #expect(try PBLiteValue(json: Data("[null]".utf8)) == .array([.null]))
    }

    /// Upstream declines to log an unknown field whose value is one of
    /// `[], "", 0` (pblite.py:114); this is that predicate.
    @Test("only [], \"\" and 0 count as trivial")
    func triviality() {
        #expect(PBLiteValue.array([]).isTrivial)
        #expect(PBLiteValue.string("").isTrivial)
        #expect(PBLiteValue.number(.integer(0)).isTrivial)
        #expect(!PBLiteValue.number(.integer(1)).isTrivial)
        #expect(!PBLiteValue.bool(false).isTrivial)
        #expect(!PBLiteValue.null.isTrivial)
    }
}
