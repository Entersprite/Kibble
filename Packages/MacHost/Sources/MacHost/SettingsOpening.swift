import SwiftUI

/// Hands its content a way to open the app's Settings window, for
/// `ChatSceneActions.showSettings`.
///
/// SwiftUI's `openSettings` is read through `@Environment`, which only a view
/// can do, and the app's `App` struct is not one. So this is the one view that
/// reads it, and the shell wraps the window in it.
public struct SettingsOpening<Content: View>: View {
    @Environment(\.openSettings) private var openSettings
    private let content: (@escaping () -> Void) -> Content

    public init(@ViewBuilder content: @escaping (@escaping () -> Void) -> Content) {
        self.content = content
    }

    public var body: some View {
        content { openSettings() }
    }
}
