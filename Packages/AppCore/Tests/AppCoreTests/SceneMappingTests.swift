import ChatKit
import DesignSystem
import Foundation
import SyncEngine
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
        let services = try FakeLaunchServices()
        services.launchReportRequested = true
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

    @Test func pagingAndCacheTrimmingPreserveTheRunningTranscript() async throws {
        let services = try FakeLaunchServices()
        let conversation = Conversation.ID("opaque/history")
        let messages = (0 ..< 150).map { index in
            Message(
                id: Message.ID("message/\(index)"), conversationID: conversation,
                threadID: MessageThread.ID("thread/\(index)"), sender: Member.ID("sender"),
                text: "Message \(index)", createdAt: Date(timeIntervalSince1970: Double(index))
            )
        }
        try services.store.apply([.replaceConversations([
            Conversation(id: conversation, kind: .space, title: "History")
        ])] + messages.map(StoreWrite.upsertMessage))
        let environment = AppEnvironment(services: services)
        await environment.start()
        environment.actions.select(conversation)
        for _ in 0 ..< 1000 {
            if environment.sceneState.messages.count == 100 {
                break
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        let visible = environment.sceneState.messages
        #expect(visible == Array(messages.suffix(100)))
        #expect(environment.sceneState.hasOlderMessages)
        #expect(!environment.sceneState.hasNewerMessages)
        #expect(environment.actions.loadOlderMessages != nil)
        #expect(environment.actions.loadNewerMessages != nil)

        environment.releasePresentationCaches()
        #expect(environment.sceneState.messages == visible)
        #expect(environment.sceneState.hasOlderMessages)
        #expect(try services.store.messages(in: conversation) == messages)
        environment.actions.openMention?(conversation, messages[0].id)
        for _ in 0 ..< 1000 {
            if environment.sceneState.messages.first?.id == messages[0].id {
                break
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(environment.sceneState.messages.first?.id == messages[0].id)
        #expect(environment.sceneState.newerMessagesAreLatestJump)
        await environment.signOut()
        #expect(environment.actions.loadOlderMessages == nil)
        #expect(environment.actions.loadNewerMessages == nil)
    }

    @Test func aRunningSceneCarriesTheSessionsConnectionServiceAndSignOutClearsIt() async throws {
        let services = try FakeLaunchServices()
        let service = ConnectionService(name: "Google Chat", operatorName: "Google")
        services.sessionConnectionService = service
        let environment = AppEnvironment(services: services)
        await environment.start()

        #expect(environment.sceneState.connectionService == service)
        await environment.signOut()
        #expect(environment.sceneState.connectionService == nil)
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

        let probing = try FakeLaunchServices()
        probing.launchReportRequested = true
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
        environment.actions.send(ComposedMessage(text: "hello"))

        #expect(try services.store.messages(in: Conversation.ID("space/1")).isEmpty)
    }

    /// Mention non-members spec §3.4: the composer's three new actions do
    /// nothing, and answer nobody, without a running session.
    @Test func thePeopleActionsAreInertWhenNothingIsRunning() async throws {
        let services = try FakeLaunchServices()
        services.makeSessionFailure = ChatError.unknown("boom")
        let environment = AppEnvironment(services: services)
        await environment.start()

        environment.actions.directoryQuery?("o")
        environment.actions.memberPicked?(Member.ID("u"))
        let outside = await environment.actions.nonMembers?(ComposedMessage(text: "x")) ?? ComposerOutsiders()
        #expect(outside.people.isEmpty)
        #expect(environment.sceneState.directoryResults.isEmpty)
        #expect(!environment.sceneState.offersOutsideMentions)
        #expect(environment.actions.addAndSend == nil)
    }

    /// Outsiders are offered in a group chat as in a space, never in a 1:1
    /// DM, and only on a backend that can mention them.
    @Test func aGroupChatOffersOutsidersAndADirectMessageDoesNot() async throws {
        var capabilities = Capabilities(canSendMessages: true)
        capabilities.canMention = true
        capabilities.canMentionNonMembers = true
        let services = try FakeLaunchServices(backendCapabilities: capabilities)
        let group = Conversation.ID("space/group")
        let direct = Conversation.ID("dm/1")
        try services.store.apply([.replaceConversations([
            Conversation(id: group, kind: .groupDirectMessage),
            Conversation(id: direct, kind: .directMessage)
        ])])
        let environment = AppEnvironment(services: services)
        await environment.start()
        await Task.yield()
        try await Task.sleep(for: .milliseconds(50))

        environment.actions.select(group)
        #expect(environment.sceneState.offersOutsideMentions)
        #expect(environment.actions.addAndSend != nil)
        environment.actions.select(direct)
        #expect(!environment.sceneState.offersOutsideMentions)
    }

    @Test func theModelsAnswerAtReturnKeepsHowTheyCanBeAdded() {
        let people = [Member.ID("u")]
        #expect(AppEnvironment.outsiders(NonMembers(people: people, adding: .beforeSending))
            == ComposerOutsiders(people: people, adding: .beforeSending))
        #expect(AppEnvironment.outsiders(NonMembers(people: people, adding: .byMention)).adding == .byMention)
        #expect(AppEnvironment.outsiders(NonMembers(people: people, adding: .unavailable))
            .adding == .unavailable)
    }

    @Test func theUnreadTotalIsZeroBeforeAnythingRuns() throws {
        let services = try FakeLaunchServices()
        #expect(AppEnvironment(services: services).totalUnread == 0)
    }
}
