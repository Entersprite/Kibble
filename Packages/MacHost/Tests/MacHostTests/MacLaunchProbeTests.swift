import Testing
@testable import MacHost

struct MacLaunchProbeTests {
    @Test func reportProbesAreSelectedByName() {
        let cases: [(String, MacLaunchProbe)] = [
            ("keychain", .keychain), ("api", .api), ("punctual", .punctual),
            ("upload", .upload), ("people", .people), ("edit", .edit),
            ("search", .search), ("spaces", .spaces), ("meet-resolve", .meetResolve)
        ]
        for (flag, expected) in cases {
            #expect(MacLaunchProbe.parsing(["Kibble", "--probe=\(flag)"]) == expected)
        }
        #if DEBUG
            #expect(MacLaunchProbe.parsing(["Kibble", "--probe=meet-call"]) == .meetCall)
            #expect(MacLaunchProbe.parsing(["Kibble", "--probe=notification-sound"]) == .notificationSound)
        #else
            #expect(MacLaunchProbe.parsing(["Kibble", "--probe=meet-call"]) == nil)
            #expect(MacLaunchProbe.parsing(["Kibble", "--probe=notification-sound"]) == nil)
        #endif
    }

    @Test func appInstrumentationDoesNotReplaceTheLaunch() {
        for flag in ["appnap", "markread", "channeltrace", "events"] {
            #expect(MacLaunchProbe.parsing(["Kibble", "--probe=\(flag)"]) == nil)
        }
    }
}
