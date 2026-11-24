import ChatKit
import SwiftUI

/// The Rooms section of Meeting Activities: the breakout rooms there are,
/// who is in each, opening and closing them, and making new ones.
struct CallActivityRoomsView: View {
    let state: CallActivitiesState
    let busy: Bool
    @Binding var roomNames: [String]
    let submit: (CallActivity, (() -> Void)?) -> Void

    var body: some View {
        if state.rooms.isEmpty {
            Section { CallActivityEmptyRow(text: "No breakout rooms yet.") }
        } else {
            Section {
                ForEach(state.rooms) { room in
                    row(room)
                }
                if offers("openRooms") || offers("closeRooms") {
                    HStack {
                        if offers("openRooms") {
                            Button("Open Rooms") { submit(CallActivity("openRooms"), nil) }
                                .disabled(!can("openRooms"))
                        }
                        if offers("closeRooms") {
                            Button("Close Rooms") { submit(CallActivity("closeRooms"), nil) }
                                .disabled(!can("closeRooms"))
                        }
                    }
                }
            }
        }
        if offers("returnToMainRoom") {
            Section {
                Button("Return to Main Room") { submit(CallActivity("returnToMainRoom"), nil) }
                    .disabled(busy)
            }
        }
        if offers("createRooms") {
            Section("New Rooms") {
                CallLineFields(lines: $roomNames, title: "Room")
                Button("Create Rooms") {
                    submit(CallActivity("createRooms", options: CallActivityCopy.filled(roomNames))) {
                        roomNames = CallActivityDrafts.emptyRoomNames
                    }
                }
                .disabled(!can("createRooms") || CallActivityCopy.filled(roomNames).isEmpty)
            }
        }
    }

    private func row(_ room: CallBreakoutRoom) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                if offers("assignRoom"), !state.people.isEmpty {
                    Menu("Assign") {
                        ForEach(state.people) { person in
                            // A checkmark is how a menu shows who is in the room.
                            Toggle(person.name, isOn: Binding(
                                get: { room.participants.contains(person.id) },
                                set: { _ in toggle(person.id, in: room) }
                            ))
                        }
                    }
                    .controlSize(.small)
                    .fixedSize()
                    .disabled(!can("assignRoom"))
                    .accessibilityLabel("Assign people to \(room.name)")
                }
                if room.isOpen, room.joinURL != nil {
                    Button("Join") { submit(CallActivity("joinRoom", resourceID: room.id), nil) }
                        .controlSize(.small)
                        .disabled(busy)
                        .accessibilityLabel("Join \(room.name)")
                }
            }
        } label: {
            Text(room.name)
            Text(Self.subtitle(for: room))
        }
    }

    /// Open or closed, then how many people are assigned, when any are.
    static func subtitle(for room: CallBreakoutRoom) -> String {
        let state = room.isOpen ? "Open" : "Closed"
        switch room.participants.count {
        case 0: return state
        case 1: return state + " · 1 person"
        default: return state + " · \(room.participants.count) people"
        }
    }

    private func toggle(_ person: UUID, in room: CallBreakoutRoom) {
        var request = CallActivity("assignRoom", resourceID: room.id)
        request.participantIDs = room.participants.contains(person)
            ? room.participants.filter { $0 != person }
            : room.participants + [person]
        submit(request, nil)
    }

    private func offers(_ action: String) -> Bool {
        state.availableActions.contains(action)
    }

    private func can(_ action: String) -> Bool {
        !busy && offers(action)
    }
}
