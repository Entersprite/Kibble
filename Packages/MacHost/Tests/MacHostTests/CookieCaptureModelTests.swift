import Foundation
import Testing
@testable import MacHost

/// Spec §6.4 - the login window's decisions, with no web view and no Keychain.
///
/// `pageSettled` is synchronous and hands off to a Task, so each test yields
/// before asserting. That is the shape of the production call too: WebKit
/// calls the delegate on the main actor and the cookie read is async.
@MainActor
struct CookieCaptureModelTests {
    private func settle(_ model: CookieCaptureModel, _ view: FakeLoginWebView) async throws {
        // Mirrors production: `CookieCaptureView.WebView.makeNSView` calls
        // `attach(_:)` once, before the navigation delegate ever calls
        // `pageSettled`/`failed` - `capture()` reads the attached weak
        // reference, not `pageSettled`'s parameter. Calling `attach` again on
        // every settle is harmless: it is the same instance each time, exactly
        // as it would be across several navigation callbacks in production.
        model.attach(view)
        model.pageSettled(view)
        await Task.yield()
        try await Task.sleep(for: .milliseconds(50))
    }

    /// Every model in this suite gets a `FakeCaptureCustody`. Nothing here may
    /// reach the real Keychain - see ruling R7.
    private func model(
        autoSaveAllowed: Bool = false,
        directory: URL? = nil,
        custody: FakeCaptureCustody = FakeCaptureCustody()
    ) -> CookieCaptureModel {
        CookieCaptureModel(
            autoSaveAllowed: autoSaveAllowed,
            custody: custody,
            reportDirectory: directory ?? FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
        )
    }

    /// The whole re-scope of spike 2: `COMPASS` and `OSID` are issued by Chat,
    /// not by the accounts host, so a capture taken when sign-in completes
    /// looks complete and is missing exactly the two cookies that matter.
    @Test func aPageThatIsNotChatYetIsNotCaptured() async throws {
        let view = FakeLoginWebView(url: "https://accounts.google.com/signin")
        view.cookies = [FakeLoginWebView.chatCookie()]
        let model = model()

        try await settle(model, view)

        #expect(view.cookieReadCount == 0)
        #expect(model.status.contains("waiting for Chat"))
    }

    @Test func chatItselfIsCaptured() async throws {
        let view = FakeLoginWebView(url: "https://chat.google.com/")
        view.cookies = [FakeLoginWebView.chatCookie()]
        let model = model()

        try await settle(model, view)

        #expect(view.cookieReadCount == 1)
    }

    /// `pageSettled` fires on every navigation that settles on Chat's origin,
    /// and Google's post-login redirect chain settles more than once. Without
    /// the latch a later, unluckier navigation could silently replace a good
    /// session with a worse one.
    @Test func theAutomaticSaveIsSpentExactlyOnce() async throws {
        let view = FakeLoginWebView(url: "https://chat.google.com/")
        view.cookies = [FakeLoginWebView.chatCookie()]
        let custody = FakeCaptureCustody()
        let model = model(autoSaveAllowed: true, custody: custody)

        try await settle(model, view)
        try await settle(model, view)
        try await settle(model, view)

        // Exactly one, not "at most one": an earlier draft asserted `<= 1`,
        // which passes when the latch never fires at all and so would have
        // told us nothing.
        #expect(custody.saveCount == 1)
        // Every settle still reads the cookies - the latch gates the save,
        // not the capture, because the report is worth writing each time.
        #expect(view.cookieReadCount == 3)
    }

    /// Defaults to `false` - the safe behaviour - so a call site that forgets
    /// to pass it gets the manual button rather than a silent auto-save.
    @Test func withoutPermissionNothingSavesByItself() async throws {
        let view = FakeLoginWebView(url: "https://chat.google.com/")
        view.cookies = [FakeLoginWebView.chatCookie()]
        let custody = FakeCaptureCustody()
        let model = model(autoSaveAllowed: false, custody: custody)

        try await settle(model, view)

        #expect(custody.saveCount == 0)
        #expect(model.showsManualControls)
    }

    @Test func aCaptureWithNoChatCookieCannotBeSaved() async throws {
        let view = FakeLoginWebView(url: "https://chat.google.com/")
        view.cookies = []
        let model = model()

        try await settle(model, view)

        #expect(!model.canSave)
    }

    /// Auto-save exists precisely so the manual buttons need no press; while
    /// it is still working towards one they are confusing furniture. They come
    /// back once the one automatic attempt has been spent, because that is
    /// when either outcome is knowable and they are the only way forward from
    /// a capture that never became a session.
    @Test func theManualControlsAppearOnlyWhenTheyAreTheWayForward() async throws {
        let manual = model(autoSaveAllowed: false)
        #expect(manual.showsManualControls)

        let view = FakeLoginWebView(url: "https://chat.google.com/")
        view.cookies = [FakeLoginWebView.chatCookie()]
        let automatic = model(autoSaveAllowed: true)
        #expect(!automatic.showsManualControls)

        try await settle(automatic, view)
        #expect(automatic.showsManualControls)
    }

    @Test func aNavigationFailureIsSurfacedRatherThanSwallowed() async {
        let view = FakeLoginWebView(url: "https://chat.google.com/")
        let model = model()

        model.failed(view, URLError(.notConnectedToInternet))
        await Task.yield()

        #expect(model.status.contains("Navigation failed"))
    }

    @Test func everyCookieFlagSurvivesTheMapping() async throws {
        let expires = Date(timeIntervalSince1970: 1_788_166_800)
        let cookie = try #require(HTTPCookie(properties: [
            .name: "COMPASS",
            .value: "secret",
            .domain: "chat.google.com",
            .path: "/u/0",
            .secure: "TRUE",
            .expires: expires
        ]))
        let view = FakeLoginWebView(url: "https://chat.google.com/")
        view.cookies = [cookie]
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let model = model(directory: directory)

        try await settle(model, view)

        // The report is the observable surface, and it must never carry the
        // value. Names, domains, paths and counts only.
        let report = try String(
            contentsOf: directory.appendingPathComponent("cookie-capture-report.txt"),
            encoding: .utf8
        )
        #expect(report.contains("COMPASS"))
        #expect(!report.contains("secret"))
    }

    /// The capture was fine and storing it failed. Distinct from the case
    /// below, and the distinction is the whole point: one says "try again",
    /// the other says "your Keychain is refusing this app", and sending
    /// someone to the wrong one wastes a two-factor login.
    @Test func aCustodyThatRefusesSaysSoAndDoesNotClaimSuccess() async throws {
        struct Refused: Error {}
        let view = FakeLoginWebView(url: "https://chat.google.com/")
        view.cookies = [FakeLoginWebView.chatCookie()]
        let custody = FakeCaptureCustody()
        custody.saveFailure = Refused()
        let model = model(autoSaveAllowed: false, custody: custody)

        try await settle(model, view)
        let saved = await model.save()

        #expect(!saved)
        #expect(model.status.contains("Could not save"))
    }

    /// Nothing in the capture belonged to Chat. Not an error - a capture taken
    /// too early - so the wording must not blame the Keychain.
    @Test func aCaptureWithNothingForChatSaysNothingToSave() async throws {
        let view = FakeLoginWebView(url: "https://chat.google.com/")
        view.cookies = [FakeLoginWebView.chatCookie()]
        let custody = FakeCaptureCustody()
        custody.saveSucceeds = false
        let model = model(autoSaveAllowed: false, custody: custody)

        try await settle(model, view)
        let saved = await model.save()

        #expect(!saved)
        #expect(model.status.contains("Nothing to save"))
        #expect(!model.status.contains("Could not save"))
    }
}
