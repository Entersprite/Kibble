import Foundation
import Testing
@testable import LocalBridgeBackend

/// The probe prints shapes, never content (CLAUDE.md, "mask by parsing").
struct SearchProbeReportTests {
    /// Lowercase on purpose: a masker that only hid uppercase would pass a
    /// test whose secret was uppercase (session 36).
    @Test func aShapeHidesEveryString() {
        let value: [Any] = ["secretword", 7, NSNull(), ["inner name", [1, 2]], ["k": "v"]]
        let shape = SearchProbeReport.shape(of: value, depth: 4)
        #expect(!shape.contains("secretword"))
        #expect(!shape.contains("inner name"))
        #expect(shape == #"[s10, 7, null, [s10, [1, 2]], {k: s1}]"#)
    }

    @Test func aShapeStopsAtItsDepth() {
        #expect(SearchProbeReport.shape(of: [[["deep"]]], depth: 1) == "[<list 1>]")
    }

    @Test func aLargeNumberIsReportedByItsDigits() {
        #expect(SearchProbeReport.shape(of: [1_790_000_000_000], depth: 2) == "[n13d]")
    }
}
