import SwiftUI

/// The first-run window's browser, for the app target, which names no WebKit
/// type. The window shows `pageHost`'s host as its subtitle. As it always
/// has, it writes `LoginTrace` and answers the page's dialogs itself
/// (`LoginDialogPolicy.answer`).
public struct CookieCaptureBrowser: View {
    private let model: CookieCaptureModel
    private let traces: Bool
    private let pageHost: @MainActor (String) -> Void

    public init(
        model: CookieCaptureModel, traces: Bool = false,
        pageHost: @escaping @MainActor (String) -> Void = { _ in }
    ) {
        self.model = model
        self.traces = traces
        self.pageHost = pageHost
    }

    public var body: some View {
        browser.id(model.browserAttempt)
    }

    var browser: LoginBrowser {
        LoginBrowser(capturing: model, traces: traces, dialogs: .answer, pageHost: pageHost)
    }
}

/// The capture model's buttons, the same in every window that signs in with
/// it. None of them takes Return, which belongs to the page's own form.
public struct CookieCaptureButtons: View {
    private let model: CookieCaptureModel

    public init(model: CookieCaptureModel) {
        self.model = model
    }

    public var body: some View {
        if let setup = model.callSetup, setup.isActive {
            Button("Try Again") { setup.retry() }
                .disabled(setup.isSaving || setup.isFinishing)
            Button("Continue to Chat") { Task { await setup.continueToChat() } }
                .disabled(setup.isFinishing)
        } else {
            if model.canRestartSignIn {
                Button("Restart Sign-In") { model.restartSignIn() }
            }
            if model.showsManualControls {
                Button("Capture Now") { model.capture() }
                Button("Save and Continue") { Task { await model.save() } }
                    .disabled(!model.canSave)
            }
        }
    }
}
