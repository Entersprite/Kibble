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
        browser
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
        } else if model.showsManualControls {
            // Shown once automatic saving can no longer finish on its own,
            // so a failed automatic capture is never a dead end
            // (`CookieCaptureModel.showsManualControls`).
            Button("Capture Now") { model.capture() }
            // `save()` completes sign-in itself, behind the same latch as the
            // automatic save, so a press that lands while that save is in
            // flight cannot leave the window twice
            // (`CookieCaptureModel.hasCompleted`).
            Button("Save and Continue") { Task { await model.save() } }
                .disabled(!model.canSave)
        }
    }
}
