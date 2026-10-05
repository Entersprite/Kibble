import ChatKit
import Foundation
import Testing
@testable import AppCore

/// `ChatSceneActions.reactions` exists only while a session runs on a backend
/// that can react (`CLAUDE.md`: never draw a control the seam cannot honour).
@MainActor
struct ReactionWiringTests {
    private func running(canReact: Bool, canFetchCustomEmoji: Bool = false) async throws -> AppEnvironment {
        let services = try FakeLaunchServices(
            backendCapabilities: Capabilities(
                canSendMessages: true, canReact: canReact, canFetchCustomEmoji: canFetchCustomEmoji
            )
        )
        let environment = AppEnvironment(services: services)
        await environment.start()
        guard case .running = environment.phase else {
            Issue.record("expected .running, got \(environment.phase)")
            return environment
        }
        return environment
    }

    @Test func withoutTheCapabilityNoReactionActionIsOffered() async throws {
        let environment = try await running(canReact: false)
        #expect(environment.actions.reactions == nil)
    }

    @Test func withTheCapabilityTheActionIsOffered() async throws {
        let environment = try await running(canReact: true)
        #expect(environment.actions.reactions != nil)
    }

    @Test func withoutTheImageCapabilityNoImageLoaderIsOffered() async throws {
        let environment = try await running(canReact: true)
        #expect(environment.actions.reactions?.customImage == nil)
    }

    @Test func withTheImageCapabilityTheLoaderIsOffered() async throws {
        let environment = try await running(canReact: true, canFetchCustomEmoji: true)
        #expect(environment.actions.reactions?.customImage != nil)
    }

    /// Slice 2: the skin tone is the app's, and survives a new environment on
    /// the same defaults (reactions spec §3).
    @Test func theSkinToneIsSavedAndReadBack() async throws {
        let defaults = try #require(UserDefaults(suiteName: "reaction-wiring-\(UUID().uuidString)"))
        let services = try FakeLaunchServices(
            backendCapabilities: Capabilities(canSendMessages: true, canReact: true)
        )
        let first = AppEnvironment(services: services, preferences: defaults)
        await first.start()
        let actions = try #require(first.actions.reactions)
        #expect(actions.skinTone == .none)
        actions.setSkinTone(.medium)
        #expect(first.actions.reactions?.skinTone == .medium)
        let second = AppEnvironment(services: services, preferences: defaults)
        #expect(second.skinTone == .medium)
    }

    /// Slice 2: the actions read the running model's recents, at call time.
    /// (Recording on an accepted add is `EmojiRecentsTests`' in SyncEngine;
    /// this fake backend serves no conversations to react in.)
    @Test func theActionsReadTheRunningSessionsRecents() async throws {
        let services = try FakeLaunchServices(
            backendCapabilities: Capabilities(canSendMessages: true, canReact: true)
        )
        let environment = AppEnvironment(services: services)
        await environment.start()
        let actions = try #require(environment.actions.reactions)
        #expect(actions.recents().isEmpty)
        try services.store.recordReactionUse(ReactionChoice(emoji: "🛞"), at: Date())
        #expect(actions.recents().map(\.emoji) == ["🛞"])
    }
}
