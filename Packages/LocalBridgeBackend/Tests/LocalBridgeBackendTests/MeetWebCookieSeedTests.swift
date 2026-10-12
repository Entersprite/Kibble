import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

struct MeetWebCookieSeedTests {
    private actor Store: CredentialStore {
        var session: StoredSession?

        init(session: StoredSession?) {
            self.session = session
        }

        func currentSession() async throws -> StoredSession? {
            session
        }

        func store(_ session: StoredSession) async throws {
            self.session = session
        }

        func invalidate() async throws {
            session = nil
        }
    }

    @Test func onlyMeetScopedCookiesEnterTheWebView() async throws {
        let cookies = try #require(SessionCookies(cookies: [
            .init(name: "shared", value: "one", domain: ".google.com", path: "/"),
            .init(name: "chatOnly", value: "two", domain: "chat.google.com", path: "/"),
            .init(name: "other", value: "three", domain: "other.example", path: "/")
        ]))
        let session = StoredSession(credential: cookies, capturedAt: .now, expiresAt: nil)
        let result = try await MeetWebCredentials.seeds(from: Store(session: session))
        #expect(result.map(\.name) == ["shared"])
        #expect(result.first?.domain == ".google.com")
    }

    @Test func anExpiredSessionSeedsNothing() async throws {
        let cookies = try #require(SessionCookies(cookies: [
            .init(name: "shared", value: "one", domain: ".google.com", path: "/")
        ]))
        let session = StoredSession(
            credential: cookies, capturedAt: .distantPast, expiresAt: .distantPast
        )
        let result = try await MeetWebCredentials.seeds(from: Store(session: session))
        #expect(result.isEmpty)
    }
}
