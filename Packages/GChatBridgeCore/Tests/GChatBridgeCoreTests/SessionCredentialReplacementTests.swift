import Foundation
import Testing
@testable import GChatBridgeCore

@Suite(.timeLimit(.minutes(1)))
struct SessionCredentialReplacementTests {
    @Test func verifiedHostReplacementPreservesOtherDomainsAndOrdersPersistence() async throws {
        let sink = CredentialSink()
        let original = try #require(SessionCookies(cookies: [
            .init(name: "SID", value: "shared", domain: ".google.com", path: "/"),
            .init(name: "COMPASS", value: "old", domain: "chat.google.com", path: "/"),
            .init(name: "OLD", value: "retired", domain: "meet.google.com", path: "/")
        ]))
        let credentials = SessionCredentials(original, onRotation: { await sink.save($0) })
        let rotation = Task {
            await credentials.absorb(
                HTTPHeaders([("Set-Cookie", "COMPASS=rotated; Path=/")]),
                from: URL(string: "https://chat.google.com/")!
            )
        }
        for _ in 0 ..< 10000 {
            if await sink.isHeld {
                break
            }
            await Task.yield()
        }
        try #require(await sink.isHeld)
        let replacement = Task {
            await credentials.replaceCookies([
                .init(name: "NEW", value: "verified", domain: "meet.google.com", path: "/")
            ], forDomains: ["meet.google.com"])
        }
        for _ in 0 ..< 10000 {
            if await credentials.snapshot?["NEW"] == "verified" {
                break
            }
            await Task.yield()
        }
        #expect(await credentials.snapshot?["NEW"] == "verified")
        #expect(await sink.values.isEmpty)
        await sink.release()
        await rotation.value
        await replacement.value
        let final = try #require(await sink.values.last)
        #expect(final["NEW"] == "verified")
        #expect(final["OLD"] == nil)
        #expect(final["COMPASS"] == "rotated")
        #expect(final["SID"] == "shared")
        #expect(await sink.values.count == 2)
    }
}

private actor CredentialSink {
    var values: [SessionCookies] = []
    var pending: CheckedContinuation<Void, Never>?
    var hasHeld = false
    var isHeld: Bool {
        pending != nil
    }

    func save(_ cookies: SessionCookies) async {
        if !hasHeld {
            hasHeld = true
            await withCheckedContinuation { pending = $0 }
        }
        values.append(cookies)
    }

    func release() {
        pending?.resume(); pending = nil
    }
}
