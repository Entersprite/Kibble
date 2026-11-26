import AppCore
import ChatKit
import FixtureBackend
import Testing
@testable import MacHost

@MainActor
struct ShowcaseLaunchTests {
    @Test func fixtureLaunchUsesTheShowcaseWorldIdentityClockAndCallDirectory() async throws {
        let services = SystemLaunchServices(arguments: LaunchArguments(backend: .fixture))
        let session = try await services.makeSession()
        let backend = try #require(session.backend as? FakeBackend)
        #expect(await backend.currentWorld == FixtureWorld.showcase)
        #expect(session.me == Showcase.alex)
        #expect(session.now() == FixtureWorld.showcase.startedAt)
        let calls = try #require(session.audioCalls as? FixtureAudioCallService)
        #expect(calls.recipients.contains { $0.conversationID == Showcase.mayaDM })
        let conversations = Set(FixtureWorld.showcase.conversations.map(\.id))
        #expect(calls.recipients.allSatisfy { conversations.contains($0.conversationID) })
    }
}
