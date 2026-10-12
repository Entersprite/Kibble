import ChatKit
import SwiftUI

/// What your avatar's menu in the sidebar footer holds: your status where the
/// backend can set it and the host supplies both actions, then Sign Out…
/// where the host offers it.
@MainActor
enum AccountMenu {
    enum Section: Equatable {
        case status
        case signOut
    }

    static func sections(state: ChatSceneState, actions: ChatSceneActions) -> [Section] {
        var sections: [Section] = []
        if state.capabilities.canSetStatus, actions.setStatus != nil, actions.setAvailability != nil {
            sections.append(.status)
        }
        if actions.signOut != nil {
            sections.append(.signOut)
        }
        return sections
    }
}

/// Your account, from your avatar and name in the sidebar footer: your
/// availability and custom status (set-your-status spec §5.1), and Sign Out…
/// (`AccountMenu` decides which). A click opens it, and so does a right-click.
struct OwnAccountMenu<Label: View>: View {
    let state: ChatSceneState
    let actions: ChatSceneActions
    @ViewBuilder let label: () -> Label

    @State private var editing = false

    private var status: MemberStatus? {
        Display.ownStatus(directory: state.directory, me: state.me, connection: state.connection, now: .now)
    }

    var body: some View {
        let sections = AccountMenu.sections(state: state, actions: actions)
        Menu {
            items(sections)
        } label: {
            label()
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .contextMenu { items(sections) }
        .help(sections.contains(.status) ? "Set your status" : "Your account")
        .sheet(isPresented: $editing) {
            SetStatusSheet(current: status, reactions: actions.reactions) { actions.setStatus?($0) }
        }
    }

    @ViewBuilder private func items(_ sections: [AccountMenu.Section]) -> some View {
        if sections.contains(.status) {
            statusItems
        }
        if sections.contains(.signOut), let signOut = actions.signOut {
            if sections.contains(.status) {
                Divider()
            }
            // The host's confirmation follows (`ChatSceneActions.signOut`).
            Button("Sign Out…", action: signOut)
        }
    }

    @ViewBuilder private var statusItems: some View {
        let model = StatusMenuModel(availability: state.availability, status: status, now: .now)
        Toggle(
            "Automatic",
            isOn: MenuCheck.binding(isOn: model.isAutomatic) { actions.setAvailability?(.automatic) }
        )
        // Ruling 3: a submenu cannot be checked, so its title says until when.
        Menu(model.doNotDisturbTitle) {
            ForEach(model.doNotDisturbChoices, id: \.self) { choice in
                Button(choice.title) {
                    if let until = choice.until(now: .now, calendar: .current) {
                        actions.setAvailability?(.doNotDisturb(until: until))
                    }
                }
            }
        }
        Toggle("Set as away", isOn: MenuCheck.binding(isOn: model.isAway) { actions.setAvailability?(.away) })
        Divider()
        if let line = model.statusLine {
            Text(line)
        }
        Button("Set a Status…") { editing = true }
        if model.statusLine != nil {
            Button("Clear Status") { actions.setStatus?(nil) }
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
