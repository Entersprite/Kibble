import MacHost
import SwiftUI

/// The login window: Google's own sign-in, hosted.
///
/// **Spike 2 of the architecture design**, and the first version of the thing
/// that eventually replaces pasting a header by hand. Two questions it exists
/// to answer, both recorded in the session 5 journal §5: whether Google's
/// sign-in works inside an embedded `WKWebView` at all, and whether
/// `WKHTTPCookieStore` hands over everything including `HttpOnly` cookies.
///
/// The browser is `MacHost`'s, shared with Add Account and call sign-in
/// recovery: its data store is **non-persistent**, so signing in here leaves
/// nothing behind in a shared cache and signing out is deleting an object.
/// This window alone writes `LoginTrace`, as it always has.
@MainActor
struct CookieCaptureView: View {
    /// Why the person is looking at this. `nil` on a first run, where there is
    /// nothing to explain.
    let reason: String?

    /// Called once a capture has reached the Keychain. The window does not
    /// dismiss itself - the environment re-runs its launch and the phase
    /// changes underneath it, which keeps "what is on screen" a function of
    /// one value rather than of two views agreeing.
    let onSaved: () async -> Void

    @State private var model: CookieCaptureModel
    /// The page's host, for the window's subtitle.
    @State private var pageHost = ""

    /// `autoSaveAllowed` defaults to `false` - the safe behaviour, not the
    /// convenient one - so guard 2 is structural: a call site that forgets to
    /// opt in gets the manual button, never a silent auto-save, and it is
    /// `KibbleMacApp` alone that passes `true`, because `.needsSignIn` is the
    /// one place there is nothing yet in the Keychain to overwrite. See
    /// `CookieCaptureModel.autoSaveAllowed`.
    init(reason: String?, autoSaveAllowed: Bool = false, onSaved: @escaping () async -> Void) {
        self.reason = reason
        self.onSaved = onSaved
        _model = State(
            initialValue: CookieCaptureModel(
                autoSaveAllowed: autoSaveAllowed, preparesCalls: true, onSaved: onSaved
            )
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            CookieCaptureBrowser(model: model, traces: true) { pageHost = $0 }
            Divider()
            controls
        }
        .frame(minWidth: 900, minHeight: 700)
        .navigationSubtitle(pageHost)
        .task { await model.refreshStoredSession() }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                if let reason {
                    Text(reason)
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                Text(model.visibleStatus)
                    .font(.callout)
                Text(model.pageURL)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                // The nine-day fuse on COMPASS is what decides how often
                // somebody signs in again, so it belongs on screen rather than
                // in a log.
                if let stored = model.storedSession {
                    Text("Keychain: \(stored)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            CookieCaptureButtons(model: model)
        }
        .padding(12)
    }
}
