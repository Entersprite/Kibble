import Foundation
import LocalBridgeBackend
import Testing
@testable import MacHost

@MainActor
struct CallSignInSetupTests {
    private func waitFor(_ condition: @MainActor () async -> Bool) async throws {
        for _ in 0 ..< 2000 {
            if await condition() {
                return
            }
            await Task.yield()
        }
        Issue.record("Expected call sign-in state did not arrive")
        throw CancellationError()
    }

    private func model(_ custody: CallSetupCustody, completed: SignInCompletions) -> CookieCaptureModel {
        CookieCaptureModel(
            autoSaveAllowed: true, custody: custody, reportDirectory: nil, preparesCalls: true,
            onSaved: { completed.count += 1 }
        )
    }

    private func begin(
        _ model: CookieCaptureModel, view: FakeLoginWebView
    ) async throws -> CallSignInSetup {
        model.attach(view)
        model.pageSettled(view)
        let setup = try #require(model.callSetup)
        try await waitFor { setup.isActive }
        return setup
    }

    private func browser() -> FakeLoginWebView {
        let view = FakeLoginWebView(url: "https://chat.google.com/")
        view.cookies = [FakeLoginWebView.chatCookie(value: "fresh-chat")]
        return view
    }

    private func visitCalls(_ model: CookieCaptureModel, view: FakeLoginWebView) {
        view.currentURL = LoginWebViewConfiguration.calls.startURL
        view.cookies.append(HTTPCookie(properties: [
            .name: "call-auth", .value: "fresh-call", .domain: "meet.google.com",
            .path: "/", .secure: "TRUE"
        ])!)
        model.pageSettled(view)
    }

    @Test func freshChatIsSavedBeforeCallsAndBothUseTheSameBrowserCapture() async throws {
        let custody = CallSetupCustody()
        let completed = SignInCompletions()
        let model = model(custody, completed: completed)
        let view = browser()
        let setup = try await begin(model, view: view)
        let chatCount = await custody.chatCount
        #expect(chatCount == 1)
        #expect(view.destinations == [LoginWebViewConfiguration.calls.startURL])
        let completionCount = completed.count
        #expect(completionCount == 0)
        #expect(!model.showsManualControls)
        #expect(await model.save() == false)
        visitCalls(model, view: view)
        try await waitFor { completed.count == 1 }
        let captured = await custody.callCaptures
        #expect(captured.count == 1)
        #expect(captured[0].contains { $0.domain == "chat.google.com" && $0.value == "fresh-chat" })
        #expect(captured[0].contains { $0.domain == "meet.google.com" && $0.value == "fresh-call" })
        #expect(!setup.isActive)
        let finalChatCount = await custody.chatCount
        #expect(finalChatCount == 1)
        model.pageSettled(view)
        #expect(await model.save() == false)
        let finalCallCount = await custody.callCaptures.count
        #expect(finalCallCount == 1)
    }

    @Test func consentCanBeSkippedWithoutReadingOrSavingCallCookies() async throws {
        let custody = CallSetupCustody()
        let completed = SignInCompletions()
        let model = model(custody, completed: completed)
        let view = browser()
        let setup = try await begin(model, view: view)
        view.currentURL = URL(string: "https://accounts.google.com/signin?token=not-for-output")
        model.pageSettled(view)
        #expect(setup.status.contains("same Google account"))
        await setup.continueToChat()
        await setup.continueToChat()
        visitCalls(model, view: view)
        #expect(completed.count == 1)
        let captures = await custody.callCaptures
        #expect(captures.isEmpty)
        #expect(!model.showsManualControls)
    }

    @Test func mismatchedAccountDoesNotCompleteLoginOrReplaceChat() async throws {
        let custody = CallSetupCustody()
        await custody.configure(failure: MeetWebCaptureError.accountMismatch)
        let completed = SignInCompletions()
        let model = model(custody, completed: completed)
        let view = browser()
        let setup = try await begin(model, view: view)
        visitCalls(model, view: view)
        try await waitFor { !setup.isSaving }
        let completionCount = completed.count
        #expect(completionCount == 0)
        #expect(setup.isActive)
        #expect(setup.status.contains("different Google account"))
        let chatCount = await custody.chatCount
        #expect(chatCount == 1)
        await setup.continueToChat()
        #expect(completed.count == 1)
    }

    @Test func missingCallCookiesOfferRetryAndKeepChatUsable() async throws {
        let custody = CallSetupCustody()
        await custody.configure(count: 0)
        let completed = SignInCompletions()
        let model = model(custody, completed: completed)
        let view = browser()
        let setup = try await begin(model, view: view)
        view.currentURL = LoginWebViewConfiguration.calls.startURL
        model.pageSettled(view)
        try await waitFor { !setup.isSaving }
        #expect(setup.status.contains("isn't ready"))
        let completionCount = completed.count
        #expect(completionCount == 0)
        setup.retry()
        #expect(view.destinations.count == 2)
        await setup.continueToChat()
        #expect(completed.count == 1)
    }

    @Test func continueJoinsACancelledVerifierBeforeStartingTheNewSession() async throws {
        let custody = CallSetupCustody()
        await custody.configure(holdCalls: true)
        let completed = SignInCompletions()
        let model = model(custody, completed: completed)
        let view = browser()
        let setup = try await begin(model, view: view)
        visitCalls(model, view: view)
        try await waitFor { await custody.isHeld }
        let skip = Task { await setup.continueToChat() }
        try await waitFor { setup.isFinishing }
        // A verifier may ignore cancellation once its final merge is underway.
        // The new session must remain unstarted until that write has settled.
        let completionCount = completed.count
        #expect(completionCount == 0)
        model.pageSettled(view)
        #expect(await model.save() == false)
        await custody.releaseCalls()
        await skip.value
        #expect(completed.count == 1)
        #expect(!setup.isActive)
        let counts = await custody.finishedCallWrites
        #expect(counts == 1)
        let captures = await custody.callCaptures
        #expect(captures.count == 1)
    }

    @Test func manualSaveCannotOverlapAutomaticChatSave() async throws {
        let custody = CallSetupCustody()
        await custody.configure(holdChat: true)
        let completed = SignInCompletions()
        let model = model(custody, completed: completed)
        let view = browser()
        model.attach(view)
        model.pageSettled(view)
        try await waitFor { await custody.chatCount == 1 }
        #expect(!model.showsManualControls)
        #expect(await model.save() == false)
        view.cookies = [FakeLoginWebView.chatCookie(value: "later-chat")]
        model.capture()
        let count = await custody.chatCount
        #expect(count == 1)
        await custody.releaseChat()
        let setup = try #require(model.callSetup)
        try await waitFor { setup.isActive }
        await setup.continueToChat()
        #expect(completed.count == 1)
        let finalCount = await custody.chatCount
        #expect(finalCount == 1)
    }

    @Test func laterSameAccountLoginCannotReceiveAnOlderBrowsersCallCookies() async throws {
        let custody = CallSetupCustody()
        let completed = SignInCompletions()
        let model = model(custody, completed: completed)
        let view = browser()
        let setup = try await begin(model, view: view)
        let originalCapture = await custody.currentCaptureDate
        await custody.replaceChatCapture()
        visitCalls(model, view: view)
        try await waitFor { !setup.isSaving }
        #expect(setup.status.contains("Chat sign-in changed"))
        let completionCount = completed.count
        #expect(completionCount == 0)
        let dates = await custody.expectedCaptureDates
        #expect(dates == [originalCapture])
        let finished = await custody.finishedCallWrites
        #expect(finished == 0)
        await setup.continueToChat()
        #expect(completed.count == 1)
    }

    @Test func guestCallPageCannotFinishSetupButAuthenticatedRetryCan() async throws {
        let custody = CallSetupCustody()
        await custody.configure(failure: MeetWebCaptureError.callSignInVerificationFailed)
        let completed = SignInCompletions()
        let model = model(custody, completed: completed)
        let view = browser()
        let setup = try await begin(model, view: view)
        visitCalls(model, view: view)
        try await waitFor { !setup.isSaving }
        let completionCount = completed.count
        #expect(completionCount == 0)
        #expect(setup.isActive)
        #expect(setup.status.contains("Finish signing in for calls"))
        await custody.configure()
        setup.retry()
        model.pageSettled(view)
        try await waitFor { completed.count == 1 }
        #expect(!setup.isActive)
        let chatCount = await custody.chatCount
        #expect(chatCount == 1)
        let merges = await custody.finishedCallWrites
        #expect(merges == 1)
    }
}

private actor CallSetupCustody: CaptureCustody {
    private(set) var chatCount = 0
    private(set) var callCaptures: [[CapturedCookie]] = []
    private(set) var finishedCallWrites = 0
    private(set) var currentCaptureDate: Date?
    private(set) var expectedCaptureDates: [Date?] = []
    private var count = 1
    private var failure: (any Error)?
    private var holdCalls = false
    private var holdChat = false
    private var callBarrier: CheckedContinuation<Void, Never>?
    private var chatBarrier: CheckedContinuation<Void, Never>?

    var isHeld: Bool {
        callBarrier != nil
    }

    func configure(
        count: Int = 1,
        failure: (any Error)? = nil,
        holdCalls: Bool = false,
        holdChat: Bool = false
    ) {
        self.count = count
        self.failure = failure
        self.holdCalls = holdCalls
        self.holdChat = holdChat
    }

    func save(_ capture: CookieCapture) async throws -> Bool {
        chatCount += 1
        if holdChat {
            await withCheckedContinuation { chatBarrier = $0 }
        }
        currentCaptureDate = capture.report.capturedAt
        return true
    }

    func storedDescription() async throws -> String? {
        nil
    }

    func saveCallCookies(
        _ cookies: [CapturedCookie],
        belongingTo capture: CookieCapture
    ) async throws -> Int {
        callCaptures.append(cookies)
        expectedCaptureDates.append(capture.report.capturedAt)
        if holdCalls {
            await withCheckedContinuation { callBarrier = $0 }
        }
        if let failure {
            throw failure
        }
        guard currentCaptureDate == capture.report.capturedAt else {
            throw MeetWebCaptureError.sessionChangedDuringVerification
        }
        finishedCallWrites += 1
        return count
    }

    func replaceChatCapture() {
        currentCaptureDate = Date(timeIntervalSince1970: 1)
    }

    func releaseCalls() {
        holdCalls = false
        callBarrier?.resume()
        callBarrier = nil
    }

    func releaseChat() {
        holdChat = false
        chatBarrier?.resume()
        chatBarrier = nil
    }
}
