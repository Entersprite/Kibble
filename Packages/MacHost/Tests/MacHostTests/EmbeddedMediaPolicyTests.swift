import Foundation
import Testing
@testable import MacHost

struct EmbeddedMediaPolicyTests {
    @Test func onlySupportedHTTPSPlayersCanLoadAndCarryTheAppsIdentity() throws {
        let url = try #require(URL(string: "https://www.youtube-nocookie.com/embed/abcdefghijk"))
        let request = try #require(EmbeddedMediaPolicy.request(url, bundleID: "com.entersprite.kibble"))
        #expect(request.value(forHTTPHeaderField: "Referer") == "https://com.entersprite.kibble")
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        for raw in [
            "http://www.youtube-nocookie.com/embed/abcdefghijk",
            "https://www.youtube-nocookie.com.evil.example/embed/abcdefghijk",
            "https://user:password@www.youtube-nocookie.com/embed/abcdefghijk",
            "https://www.youtube-nocookie.com/watch?v=abcdefghijk",
            "https://www.youtube-nocookie.com/embed/short",
            "https://www.youtube-nocookie.com/embed/abcdefghijk?autoplay=1",
            "file:///embed/abcdefghijk"
        ] {
            let candidate = try #require(URL(string: raw))
            #expect(!EmbeddedMediaPolicy.allows(candidate))
        }
    }
}
