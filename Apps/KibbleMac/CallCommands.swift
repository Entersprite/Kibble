import DesignSystem
import MacHost
import SwiftUI

/// The menu bar's Call menu (`CallMenu`): Mute, the camera, sharing and End
/// Call for the call holding this Mac's microphone, from whichever window is
/// in front, the call window included. Drawn only while an account can place
/// a call.
struct CallCommands: Commands {
    /// Read by the shell's own body, so a change rebuilds the menu bar.
    let menu: CallMenu?
    let model: CallMenuModel

    var body: some Commands {
        if let menu {
            CommandMenu("Call") {
                ForEach(menu.entries) { entry in
                    if entry.item == .endCall {
                        Divider()
                    }
                    Button(entry.title, systemImage: entry.symbol) { perform(entry.item) }
                        .keyboardShortcut(entry.shortcut)
                        .disabled(!entry.isEnabled)
                }
            }
        }
    }

    private func perform(_ item: CallMenu.Item) {
        switch item {
        case .mute: model.toggleMute()
        case .camera: model.toggleCamera()
        case .shareScreen: model.toggleScreenSharing()
        case .endCall: model.hangUp()
        }
    }
}
