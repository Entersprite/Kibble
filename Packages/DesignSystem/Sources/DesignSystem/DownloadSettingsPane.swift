import SwiftUI

/// Values in, callbacks out - the `ChatSceneState` pattern, for Settings ›
/// Downloads.
public struct DownloadSettingsState: Equatable, Sendable {
    /// The folder's display name, e.g. "Downloads".
    public var folderName: String
    /// The folder's full path, shown as a tooltip rather than inline, since a
    /// path is rarely what a person wants to read at a glance.
    public var folderPath: String
    /// Whether the folder is still the host's built-in default, which decides
    /// what the menu's current item stands for (`currentItem`).
    public var isDefault: Bool
    /// A one-line diagnostic (e.g. a folder that could no longer be reached),
    /// drawn in the section's footer. `nil` in the ordinary case.
    public var notice: String?

    public init(folderName: String, folderPath: String, isDefault: Bool, notice: String? = nil) {
        self.folderName = folderName
        self.folderPath = folderPath
        self.isDefault = isDefault
        self.notice = notice
    }

    /// The menu's checked item. On the default folder it is the Downloads
    /// choice itself, so the menu never lists Downloads twice. A chosen folder
    /// that is gone reads as the default with a notice; choosing Downloads
    /// there forgets that folder and clears the notice, provided the menu
    /// reports a choice of its checked item ([Verify] in the running app).
    var currentItem: DownloadFolderMenuItem {
        isDefault ? .downloads : .current
    }

    /// Downloads is offered beside the current folder only once that folder
    /// is a different one.
    var offersDownloads: Bool {
        !isDefault
    }
}

/// The folder menu's rows: the folder in use, Downloads, and the row that
/// opens the folder picker.
enum DownloadFolderMenuItem: Hashable {
    case current
    case downloads
    case other
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

/// Settings › Downloads: where a downloaded file is saved, as a folder menu
/// like the save location menus elsewhere on the Mac. The folder picker and
/// the bookmark are the host's; this draws values and hands back two
/// callbacks.
public struct DownloadSettingsPane: View {
    private let state: DownloadSettingsState
    private let actions: DownloadSettingsActions

    public init(state: DownloadSettingsState, actions: DownloadSettingsActions) {
        self.state = state
        self.actions = actions
    }

    public var body: some View {
        Form {
            Section {
                Picker("Save downloads to", selection: folderSelection) {
                    Label(state.folderName, systemImage: "folder").tag(state.currentItem)
                    if state.offersDownloads {
                        Text("Downloads").tag(DownloadFolderMenuItem.downloads)
                    }
                    Divider()
                    Text("Other…").tag(DownloadFolderMenuItem.other)
                }
                // The full path on hover, rather than inline: a path is rarely
                // what a person wants to read at a glance.
                .help(state.folderPath)
            } footer: {
                if let notice = state.notice {
                    Text(notice)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Always reads the folder in use. Other… only opens the host's picker,
    /// so a canceled choice leaves the menu on the current folder, as the
    /// ringtone menu does after a canceled Select Audio File….
    private var folderSelection: Binding<DownloadFolderMenuItem> {
        Binding(
            get: { state.currentItem },
            set: { item in
                switch item {
                case .current: break
                case .downloads: actions.useDefault()
                case .other: actions.choose()
                }
            }
        )
    }
}
