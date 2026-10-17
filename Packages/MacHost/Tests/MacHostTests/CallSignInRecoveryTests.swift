import Foundation
import LocalBridgeBackend
import Testing
@testable import MacHost

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct CallSignInRecoveryTests {
    private func wait(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0 ..< 10000 {
            if condition() {
                return
            }
            await Task.yield()
        }
        try #require(condition())
    }

    @Test func browserChecksChatThenCallsAndCompletesWithoutSavingChat() async throws {
        let model = CallSignInRecovery()
        var saved = 0
        var result: Bool?
        await model.install(load: { [] }, save: { _ in saved += 1; return 1 })
        model.begin { result = $0 }
        let view = FakeLoginWebView(url: "https://chat.google.com/")
        model.attach(view, seed: { _ in })
        try await wait { !model.isWorking }
        #expect(view.destinations == [LoginWebViewConfiguration.chat.startURL])
        model.pageSettled(view)
        #expect(view.destinations.last == LoginWebViewConfiguration.calls.startURL)
        view.currentURL = LoginWebViewConfiguration.calls.startURL
        model.pageSettled(view)
        try await wait { result != nil }
        #expect(result == true)
        #expect(saved == 1)
        #expect(!model.isActive)
        #expect(view.cookieReadCount == 1)
    }

    @Test func accountMismatchLeavesRetryAvailableAndDoesNotComplete() async throws {
        let model = CallSignInRecovery()
        var result: Bool?
        await model.install(load: { [] }, save: { _ in throw MeetWebCaptureError.accountMismatch })
        model.begin { result = $0 }
        let view = FakeLoginWebView(url: "https://chat.google.com/")
        model.attach(view, seed: { _ in })
        try await wait { !model.isWorking }
        model.pageSettled(view)
        view.currentURL = LoginWebViewConfiguration.calls.startURL
        model.pageSettled(view)
        try await wait { !model.isWorking }
        #expect(result == nil)
        #expect(model.status.contains("different Google account"))
        model.retry()
        #expect(view.destinations.last == LoginWebViewConfiguration.chat.startURL)
        await model.finish(restart: true)
        #expect(result == true)
    }

    @Test func invalidationJoinsAnInFlightSaveAndCannotRestartCalls() async throws {
        let model = CallSignInRecovery()
        var save: CheckedContinuation<Int, Never>?
        var result: Bool?
        await model.install(load: { [] }, save: { _ in
            await withCheckedContinuation { save = $0 }
        })
        model.begin { result = $0 }
        let view = FakeLoginWebView(url: "https://chat.google.com/")
        model.attach(view, seed: { _ in })
        try await wait { !model.isWorking }
        model.pageSettled(view)
        view.currentURL = LoginWebViewConfiguration.calls.startURL
        model.pageSettled(view)
        try await wait { save != nil }
        let close = Task { await model.finish(restart: true) }
        let invalidate = Task { await model.invalidate() }
        try await wait { !model.isAvailable }
        #expect(result == nil)
        save?.resume(returning: 1)
        await close.value
        await invalidate.value
        #expect(result == false)
        #expect(!model.isActive)
    }
}
