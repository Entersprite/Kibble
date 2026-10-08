import ChatKit
import SwiftUI

/// Your availability and custom status, from your name in the sidebar footer
/// (set-your-status spec §5.1). The footer draws it only when the backend can
/// set status and the host supplies both actions.
struct OwnStatusMenu<Label: View>: View {
    let state: ChatSceneState
    let setStatus: (MemberStatus?) -> Void
    let setAvailability: (Availability) -> Void
    let reactions: ReactionActions?
    @ViewBuilder let label: () -> Label

    @State private var editing = false

    private var status: MemberStatus? {
        Display.ownStatus(directory: state.directory, me: state.me, connection: state.connection, now: .now)
    }

    var body: some View {
        let model = StatusMenuModel(availability: state.availability, status: status, now: .now)
        Menu {
            Toggle("Automatic", isOn: choosing(model.isAutomatic) { setAvailability(.automatic) })
            // Ruling 3: a submenu cannot be checked, so its title says until when.
            Menu(model.doNotDisturbTitle) {
                ForEach(model.doNotDisturbChoices, id: \.self) { choice in
                    Button(choice.title) { setAvailability(.doNotDisturb(until: choice.until)) }
                }
            }
            Toggle("Set as away", isOn: choosing(model.isAway) { setAvailability(.away) })
            Divider()
            if let line = model.statusLine {
                Text(line)
            }
            Button("Set a Status…") { editing = true }
            if model.statusLine != nil {
                Button("Clear Status") { setStatus(nil) }
            }
        } label: {
            label()
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help("Set your status")
        .sheet(isPresented: $editing) {
            SetStatusSheet(current: status, reactions: reactions, save: setStatus)
        }
    }

    /// A checkmark row: checked when `isOn`; choosing it while unchecked acts.
    private func choosing(_ isOn: Bool, _ act: @escaping () -> Void) -> Binding<Bool> {
        Binding(get: { isOn }, set: {
            if $0 {
                act()
            }
        })
    }
}
