import Testing
@testable import MacHost

struct MacLaunchProbeTests {
    @Test func reportProbesAreSelectedByName() {
        let cases: [(String, MacLaunchProbe)] = [
            ("keychain", .keychain), ("api", .api), ("punctual", .punctual),
            ("upload", .upload), ("people", .people), ("edit", .edit),
            ("search", .search)
        ]
        for (flag, expected) in cases {
            #expect(MacLaunchProbe.parsing(["Kibble", "--probe=\(flag)"]) == expected)
        }
    }

    @Test func appInstrumentationDoesNotReplaceTheLaunch() {
        for flag in ["appnap", "markread", "channeltrace", "events"] {
            #expect(MacLaunchProbe.parsing(["Kibble", "--probe=\(flag)"]) == nil)
        }
    }
}
