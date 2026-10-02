import SwiftUI

/// Values in, callbacks out - the `ChatSceneState` pattern, for Settings ›
/// Downloads.
public struct DownloadSettingsState: Equatable, Sendable {
    /// The folder's display name, e.g. "Downloads".
    public var folderName: String
    /// The folder's full path, shown as a tooltip rather than inline, since a
    /// path is rarely what a person wants to read at a glance.
    public var folderPath: String
    /// Whether the folder is still the host's built-in default - one half
    /// of `offersUseDownloads`.
    public var isDefault: Bool
    /// A one-line diagnostic (e.g. a folder that could no longer be reached),
    /// drawn under the controls. `nil` in the ordinary case.
    public var notice: String?

    public init(folderName: String, folderPath: String, isDefault: Bool, notice: String? = nil) {
        self.folderName = folderName
        self.folderPath = folderPath
        self.isDefault = isDefault
        self.notice = notice
    }

    /// Once the folder has been changed, and whenever there is a notice:
    /// a chosen folder that is gone reads as the default with a notice, and
    /// "Use Downloads" is what forgets it and clears the notice.
    var offersUseDownloads: Bool {
        !isDefault || notice != nil
    }
}

@MainActor
public struct DownloadSettingsActions {
    /// Opens a folder picker. The picker and the security-scoped bookmark it
    /// produces are the host's; this pane only ever hands back the choice.
    public var choose: () -> Void
    /// Reverts to the host's default Downloads folder.
    public var useDefault: () -> Void

    public init(choose: @escaping () -> Void, useDefault: @escaping () -> Void) {
        self.choose = choose
        self.useDefault = useDefault
    }
}

/// Settings → Downloads: where a downloaded file is saved, and a way to
/// change it. The picker and the bookmark are the host's; this draws values
/// and hands back two callbacks.
public struct DownloadSettingsPane: View {
    private let state: DownloadSettingsState
    private let actions: DownloadSettingsActions

    public init(state: DownloadSettingsState, actions: DownloadSettingsActions) {
        self.state = state
        self.actions = actions
    }

    public var body: some View {
        Form {
            LabeledContent("Save downloads to") {
                Text(state.folderName).help(state.folderPath)
            }
            HStack {
                Button("Change…", action: actions.choose)
                if state.offersUseDownloads {
                    Button("Use Downloads", action: actions.useDefault)
                }
            }
            if let notice = state.notice {
                Text(notice).foregroundStyle(.secondary).font(.callout)
            }
        }
        .formStyle(.grouped)
    }
}
