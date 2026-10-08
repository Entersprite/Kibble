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
            Toggle(
                "Automatic",
                isOn: MenuCheck.binding(isOn: model.isAutomatic) { setAvailability(.automatic) }
            )
            // Ruling 3: a submenu cannot be checked, so its title says until when.
            Menu(model.doNotDisturbTitle) {
                ForEach(model.doNotDisturbChoices, id: \.self) { choice in
                    Button(choice.title) {
                        if let until = choice.until(now: .now, calendar: .current) {
                            setAvailability(.doNotDisturb(until: until))
                        }
                    }
                }
            }
            Toggle("Set as away", isOn: MenuCheck.binding(isOn: model.isAway) { setAvailability(.away) })
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
}

/// A checkmark row in a menu.
enum MenuCheck {
    /// Checked when `isOn`, and choosing it acts whether it was checked or
    /// not: a checkmark can be wrong (ruling 4, or a change made on another
    /// device), and the row a person picks to correct it is the checked one
    /// (review finding 3). Sending the same availability again is harmless.
    static func binding(isOn: Bool, act: @escaping () -> Void) -> Binding<Bool> {
        Binding(get: { isOn }, set: { _ in act() })
    }
}
