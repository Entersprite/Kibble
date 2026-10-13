import Testing
@testable import MacHost

struct MacLaunchProbeTests {
    @Test func reportProbesAreSelectedByName() {
        let cases: [(String, MacLaunchProbe)] = [
            ("keychain", .keychain), ("api", .api), ("punctual", .punctual),
            ("upload", .upload), ("people", .people), ("edit", .edit),
            ("search", .search), ("meet-resolve", .meetResolve)
        ]
        for (flag, expected) in cases {
            #expect(MacLaunchProbe.parsing(["Kibble", "--probe=\(flag)"]) == expected)
        }
        #if DEBUG
            #expect(MacLaunchProbe.parsing(["Kibble", "--probe=meet-call"]) == .meetCall)
        #else
            #expect(MacLaunchProbe.parsing(["Kibble", "--probe=meet-call"]) == nil)
        #endif
    }

    @Test func appInstrumentationDoesNotReplaceTheLaunch() {
        for flag in ["appnap", "markread", "channeltrace", "events"] {
            #expect(MacLaunchProbe.parsing(["Kibble", "--probe=\(flag)"]) == nil)
        }
    }
}
