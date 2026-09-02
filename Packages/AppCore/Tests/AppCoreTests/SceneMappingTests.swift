import ChatKit
import DesignSystem
import Foundation
import Testing
@testable import AppCore

/// Spec §6.3 - what each phase puts on screen, and which controls it offers.
///
/// The first two tests are the warning-triangle bug from session 15: `.failed`
/// and `.report` used to share one string field, so a clean probe report drew
/// under a warning triangle. They are separate fields now, and these are what
/// stop them being collapsed back.
@MainActor
struct SceneMappingTests {
    @Test func aProbeReportIsANoticeAndNotAnError() async throws {
        let services = try FakeLaunchServices(arguments: LaunchArguments(probe: .api))
        services.probeReport = "Written to api-probe.txt."
        let environment = AppEnvironment(services: services)
        await environment.start()

        #expect(environment.sceneState.notice == "Written to api-probe.txt.")
        #expect(environment.sceneState.lastError == nil)
    }

    @Test func aFailedLaunchIsAnErrorAndNotANotice() async throws {
        let services = try FakeLaunchServices()
        services.makeSessionFailure = ChatError.unknown("no session in the Keychain")
        let environment = AppEnvironment(services: services)
        await environment.start()

        #expect(environment.sceneState.notice == nil)
        #expect(environment.sceneState.lastError != nil)
    }

    @Test func aLaunchStillDecidingShowsAnEmptyWindow() throws {
        let services = try FakeLaunchServices()
        let environment = AppEnvironment(services: services)

        #expect(environment.sceneState.conversations.isEmpty)
        #expect(environment.sceneState.lastError == nil)
        #expect(environment.sceneState.notice == nil)
    }

    /// An earlier draft asserted `connection != .idle || messages.isEmpty`,
    /// whose right operand is always true - a tautology that would have passed
    /// against any implementation. Ruling R4 in the SDD ledger.
    ///
    /// A later version of this test - after R4's fix - asserted `me == nil`
    /// and `notice == nil`. Those are `ChatSceneState`'s own defaults, so they
    /// would have passed even with the `.running` branch forwarding nothing
    /// at all: `conversations`, `directory`, `selected`, `messages`, `typing`,
    /// `connection` and `lastError` were asserted nowhere in this suite. This
    /// version seeds the store with a real conversation before `start()`, so
    /// `conversations`, `selected` and `totalUnread` are pinned with values
    /// that cannot arrive by default.
    @Test func aRunningSessionCarriesTheModelsView() async throws {
        let services = try FakeLaunchServices()
        let space = Conversation.ID("space/1")
        try services.store.apply([.replaceConversations([
            Conversation(
                id: space,
                kind: .space,
                title: "Support",
                lastActivity: nil,
                unreadCount: 3,
                members: []
            )
        ])])
        let environment = AppEnvironment(services: services)

        await environment.start()
        // The model reaches the store through a GRDB observation, so give the
        // first value a turn to land - the same shape the other async tests
        // in this package already use (`SignOutAndEraseTests`).
        await Task.yield()
        try await Task.sleep(for: .milliseconds(50))

        guard case .running = environment.phase else {
            Issue.record("expected .running")
            return
        }
        // From `FakeLaunchBackend.capabilities`, through the model, to here.
        // `Capabilities` defaults every flag to `false`, so `true` can only be
        // a real forward.
        #expect(environment.sceneState.capabilities.canSendMessages)
        // conversations: forwarded, with a value that cannot be a default.
        #expect(environment.sceneState.conversations.map(\.id) == [space])
        #expect(environment.sceneState.conversations.first?.title == "Support")
        // selected: forwarded, driven through the action the window would use.
        environment.actions.select(space)
        #expect(environment.sceneState.selected == space)
        // The sum `totalUnread` exists to compute, taken for free from the
        // same seeded conversation - nothing else in this suite exercises it
        // beyond the before-anything-runs zero case below.
        #expect(environment.totalUnread == 3)
    }

    /// Offered **only** from `.failed`, which is the phase that had no way
    /// out. `.needsSignIn` already shows the capture window, `.running` must
    /// not invite someone to re-authenticate a working session over one
    /// transient banner, and a probe report is not a session problem at all.
    @Test func theWayBackToSignInIsOfferedOnlyFromAFailedLaunch() async throws {
        let failed = try FakeLaunchServices()
        failed.makeSessionFailure = ChatError.unknown("boom")
        let failedEnvironment = AppEnvironment(services: failed)
        await failedEnvironment.start()
        #expect(failedEnvironment.actions.signIn != nil)

        let running = try FakeLaunchServices()
        let runningEnvironment = AppEnvironment(services: running)
        await runningEnvironment.start()
        #expect(runningEnvironment.actions.signIn == nil)

        let probing = try FakeLaunchServices(arguments: LaunchArguments(probe: .api))
        let probingEnvironment = AppEnvironment(services: probing)
        await probingEnvironment.start()
        #expect(probingEnvironment.actions.signIn == nil)
    }

    @Test func signingOutIsOfferedOnlyWhileSomethingIsRunning() async throws {
        let services = try FakeLaunchServices()
        let environment = AppEnvironment(services: services)
        #expect(!environment.canSignOut)

        await environment.start()
        #expect(environment.canSignOut)
    }

    @Test func theActionsAreInertWhenNothingIsRunning() async throws {
        let services = try FakeLaunchServices()
        services.makeSessionFailure = ChatError.unknown("boom")
        let environment = AppEnvironment(services: services)
        await environment.start()

        // Must not trap or write anything. There is no model to ask.
        environment.actions.select(Conversation.ID("space/1"))
        environment.actions.send("hello")

        #expect(try services.store.messages(in: Conversation.ID("space/1")).isEmpty)
    }

    @Test func theUnreadTotalIsZeroBeforeAnythingRuns() throws {
        let services = try FakeLaunchServices()
        #expect(AppEnvironment(services: services).totalUnread == 0)
    }
}
