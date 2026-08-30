import Foundation
import Testing
@testable import ChatKit

@Suite("JSON shape reporting")
struct JSONShapeTests {
    @Test("string values are replaced by their type, never echoed")
    func redactsStrings() {
        let json = #"{"text":"a private company message"}"#
        let shape = JSONShape.describe(Data(json.utf8))
        #expect(shape.contains("text"))
        #expect(!shape.contains("private"))
        #expect(!shape.contains("company"))
    }

    /// The whole point of this type is that it is safe to hand to someone else.
    @Test("no string value anywhere survives into the output")
    func leaksNothing() {
        let secret = "SUPERSECRETVALUE"
        let json = """
        {"a":"\(secret)","b":{"c":"\(secret)"},"d":[{"e":"\(secret)"}],
         "displayName":"\(secret)"}
        """
        let shape = JSONShape.describe(Data(json.utf8))
        #expect(!shape.contains(secret))
    }

    @Test("allowlisted structural values are kept, since they carry no content")
    func keepsEnums() {
        let json = #"{"type":"HUMAN","state":"JOINED","text":"hello"}"#
        let shape = JSONShape.describe(Data(json.utf8))
        #expect(shape.contains("HUMAN"))
        #expect(shape.contains("JOINED"))
        #expect(!shape.contains("hello"))
    }

    @Test("presence counts show which keys are missing on some elements")
    func presenceCounts() {
        let json = """
        {"memberships":[
          {"name":"a","member":{"name":"u1","displayName":"X","type":"HUMAN"}},
          {"name":"b","member":{"name":"u2","type":"HUMAN"}}
        ]}
        """
        let shape = JSONShape.describe(Data(json.utf8))
        // displayName present on 1 of 2 members is exactly the signal we need.
        #expect(shape.contains("displayName"))
        #expect(shape.contains("1/2"))
    }

    @Test("array counts are reported")
    func arrayCounts() {
        let json = #"{"messages":[{"a":"x"},{"a":"y"},{"a":"z"}]}"#
        let shape = JSONShape.describe(Data(json.utf8))
        #expect(shape.contains("3"))
    }

    @Test("numbers, booleans and nulls are labelled by type")
    func scalarTypes() {
        let json = #"{"n":42,"f":1.5,"b":true,"z":null}"#
        let shape = JSONShape.describe(Data(json.utf8))
        for expected in ["number", "bool", "null"] {
            #expect(shape.contains(expected))
        }
    }

    @Test("malformed JSON reports itself rather than throwing")
    func malformed() {
        #expect(JSONShape.describe(Data("not json".utf8)).contains("could not be parsed"))
    }

    @Test("an empty array is distinguishable from a missing key")
    func emptyArray() {
        let shape = JSONShape.describe(Data(#"{"sections":[]}"#.utf8))
        #expect(shape.contains("sections"))
        #expect(shape.contains("empty"))
    }
}
