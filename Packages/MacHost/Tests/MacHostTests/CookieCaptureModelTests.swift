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
        custody: FakeCaptureCustody = FakeCaptureCustody(),
        onSaved: @escaping () async -> Void = {}
    ) -> CookieCaptureModel {
        CookieCaptureModel(
            autoSaveAllowed: autoSaveAllowed,
            custody: custody,
            reportDirectory: directory ?? FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString),
            onSaved: onSaved
        )
    }

    private func reportDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    private func report(in directory: URL) throws -> String {
        try String(
            contentsOf: directory.appendingPathComponent("cookie-capture-report.txt"),
            encoding: .utf8
        )
    }

    /// One cookie's row from the report, split back into its columns:
    /// name, domain, value length, HttpOnly, Secure, expiry, and whether it
    /// was sent - plus the excluding domain/path when it was not.
    ///
    /// The rows are hand-padded (`CookieCaptureReport.text` says why), so
    /// splitting on runs of whitespace gives the columns back exactly. The
    /// trailing space in the prefix is load-bearing: the summary block above
    /// the table has its own `COMPASS:` line, and a bare prefix match finds
    /// that one first.
    private func row(for name: String, in report: String) throws -> [String] {
        let line = try #require(
            report.split(separator: "\n").first { $0.hasPrefix(name + " ") },
            "no report row for \(name)"
        )
        return line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
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
        // Asserted here and nowhere else before: nothing in this suite used to
        // check `canSave` in its *true* state, so a mapping hard-wired to
        // `false` would have left "Save and continue" permanently disabled
        // with all 890 tests passing - killing the only recovery from a failed
        // auto-save.
        #expect(model.canSave)
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

    /// A good capture first, deliberately.
    ///
    /// This test used to settle a cookie-less page and assert `!model.canSave`
    /// against a property initialised to `false` - so deleting the very
    /// assignment it exists to check (`canSave = capture.session != nil`) left
    /// it passing. It asserted a default. Establishing `true` and then
    /// watching it go back to `false` is an assertion the default cannot
    /// satisfy in either half.
    @Test func aCaptureWithNoChatCookieCannotBeSaved() async throws {
        let view = FakeLoginWebView(url: "https://chat.google.com/")
        view.cookies = [FakeLoginWebView.chatCookie()]
        let model = model()

        try await settle(model, view)
        #expect(model.canSave)

        // The unluckier navigation the auto-save latch exists for, here doing
        // its other job: taking the button away again.
        view.cookies = []
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

    /// Every field the `HTTPCookie` to `CapturedCookie` mapping copies,
    /// checked through the one surface that renders them all.
    ///
    /// The name promised this; the test asserted two things - that the name
    /// arrived and that the value did not. A mapping that hard-wired
    /// `isSecure: false`, dropped the path, or dropped the expiry passed it
    /// unchanged.
    ///
    /// Two cookies rather than one, because three of the fields are only
    /// distinguishable in opposite states: the path is printed in a row
    /// **only** when the cookie was excluded; `HttpOnly` cannot be set through
    /// `HTTPCookie(properties:)` at all, since it comes from parsing a
    /// `Set-Cookie` header; and `Secure` asserted in one direction alone would
    /// survive being hard-wired the other way.
    @Test func everyCookieFlagSurvivesTheMapping() async throws {
        // Secure, expiring, not HttpOnly, and out of scope: `CookieScope.chat`
        // is rooted at "/", which a cookie pathed at "/u/0" does not match, so
        // this one is reported as excluded - and an excluded row is the only
        // place the path appears.
        let expires = Date().addingTimeInterval(777_600)
        let secure = try #require(HTTPCookie(properties: [
            .name: "COMPASS",
            .value: "secret",
            .domain: "chat.google.com",
            .path: "/u/0",
            .secure: "TRUE",
            .expires: expires
        ]))
        // HttpOnly, not Secure, no expiry, in scope. Parsed from a `Set-Cookie`
        // header because that is the only way `isHTTPOnly` is ever true - and
        // it being true is the linchpin the architecture design rests on: an
        // in-page scraper could not have seen this cookie at all.
        let origin = try #require(URL(string: "https://chat.google.com/"))
        let httpOnly = try #require(HTTPCookie.cookies(
            withResponseHeaderFields: [
                "Set-Cookie": "OSID=abc; Domain=chat.google.com; Path=/; HttpOnly"
            ],
            for: origin
        ).first)
        #expect(httpOnly.isHTTPOnly)
        let view = FakeLoginWebView(url: "https://chat.google.com/")
        view.cookies = [secure, httpOnly]
        let directory = reportDirectory()
        let model = model(directory: directory)

        try await settle(model, view)

        // The report is the observable surface, and it must never carry a
        // value. Names, domains, paths, flags and lengths only.
        let report = try report(in: directory)
        #expect(!report.contains("secret"))

        let compass = try row(for: "COMPASS", in: report)
        try #require(compass.count == 8)
        #expect(compass[1] == "chat.google.com")
        // The length, in place of the value it was taken from.
        #expect(compass[2] == "6")
        #expect(compass[3] == "no")
        #expect(compass[4] == "yes")
        // An expiry arrived; a dropped `expiresAt` reads "session".
        #expect(compass[5] != "session")
        #expect(compass[5].hasSuffix("d"))
        #expect(compass[6] == "excluded")
        #expect(compass[7] == "(chat.google.com/u/0)")

        let osid = try row(for: "OSID", in: report)
        try #require(osid.count == 7)
        #expect(osid[1].hasSuffix("chat.google.com"))
        #expect(osid[3] == "yes")
        #expect(osid[4] == "no")
        #expect(osid[5] == "session")
        #expect(osid[6] == "yes")
    }

    /// The two routes out of this window, both live at once.
    ///
    /// `hasAutoSaved` latches synchronously, so `showsManualControls` - and
    /// with it "Save and continue" - is already true while the automatic
    /// attempt's own Keychain write is still in flight. Both routes finished
    /// by completing sign-in, and two `AppEnvironment.signedIn()` calls built
    /// two engines and two models over one store with the first leaked and
    /// never stopped.
    @Test func signInCompletesOnceEvenWhenBothRoutesFinish() async throws {
        let view = FakeLoginWebView(url: "https://chat.google.com/")
        view.cookies = [FakeLoginWebView.chatCookie()]
        let completions = SignInCompletions()
        let model = model(autoSaveAllowed: true, onSaved: { completions.count += 1 })

        try await settle(model, view)
        #expect(completions.count == 1)
        // The button is on screen by now, and pressing it really does save.
        #expect(model.showsManualControls)
        #expect(await model.save())

        #expect(completions.count == 1)
    }

    /// F4 - the login URL reached two sinks unredacted, and one of them
    /// promises in its own doc comment that "nothing here needs redacting
    /// before it is pasted into an issue".
    ///
    /// `LoginTrace.redact(_:)` is reused rather than a second rule written,
    /// which is the same "one rule, not two" the host-matching fix in
    /// `findings.md` §24 was about.
    @Test func aSignInQueryReachesNeitherTheScreenNorTheReport() async throws {
        let view = FakeLoginWebView(url: "https://chat.google.com/u/0/?token=SECRET&hl=en")
        view.cookies = [FakeLoginWebView.chatCookie()]
        let directory = reportDirectory()
        let model = model(directory: directory)

        try await settle(model, view)

        #expect(!model.pageURL.contains("SECRET"))
        #expect(!model.pageURL.contains("token"))
        // Redacted, not blanked: host and path are what make this line worth
        // showing at all, and their absence is what a stripped query looks
        // like rather than silence.
        #expect(model.pageURL == "chat.google.com/u/0/ ?<stripped>")

        let report = try report(in: directory)
        #expect(!report.contains("SECRET"))
        #expect(!report.contains("token"))
        #expect(report.contains("chat.google.com/u/0/ ?<stripped>"))
    }

    /// The intermediate navigations are the dangerous ones: `pageSettled`
    /// fires on every settle, and a Google sign-in URL is where the one-time
    /// tokens actually live. That is why the assignment sits *above* the host
    /// gate rather than below it, and why `failed(_:_:)` needs the same
    /// treatment - a fix aimed only at `pageSettled` leaves that one behind.
    @Test func anIntermediateSignInURLIsRedactedBeforeItIsShown() async throws {
        let view = FakeLoginWebView(url: "https://accounts.google.com/signin/v2?token=SECRET")
        let model = model()

        try await settle(model, view)

        #expect(model.status.contains("waiting for Chat"))
        #expect(!model.pageURL.contains("SECRET"))
        #expect(model.pageURL == "accounts.google.com/signin/v2 ?<stripped>")

        model.failed(view, URLError(.notConnectedToInternet))

        #expect(!model.pageURL.contains("SECRET"))
        #expect(model.pageURL == "accounts.google.com/signin/v2 ?<stripped>")
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

/// Counts the exits from the login window. One sign-in, one exit - see
/// `CookieCaptureModel.hasCompleted`.
@MainActor
final class SignInCompletions {
    var count = 0
}
