import ChatKit
import SwiftUI

/// The Rooms section of Meeting Activities: the breakout rooms there are,
/// who is in each, opening and closing them, and making new ones.
struct CallActivityRoomsView: View {
    let state: CallActivitiesState
    let currentRoomID: UUID?
    let busy: Bool
    @Binding var roomNames: [String]
    let submit: (CallActivity, (() -> Void)?) -> Void

    var body: some View {
        if state.rooms.isEmpty {
            Section {
                CallActivityEmptyRow(text: state.breakoutClosing == true
                    ? "Breakout rooms are closing." : "No breakout rooms yet.")
            }
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
        let createsAndOpens = offers("createAndOpenRooms")
        let createAction = createsAndOpens ? "createAndOpenRooms" : "createRooms"
        if offers(createAction) {
            Section("New Rooms") {
                CallLineFields(lines: $roomNames, title: "Room")
                Button(createsAndOpens ? "Create and Open Rooms" : "Create Rooms") {
                    submit(CallActivity(createAction, options: CallActivityCopy.filled(roomNames))) {
                        roomNames = CallActivityDrafts.emptyRoomNames
                    }
                }
                .disabled(!can(createAction) || CallActivityCopy.filled(roomNames).isEmpty)
            }
        }
    }

    private func row(_ room: CallBreakoutRoom) -> some View {
        let isCurrent = room.id == currentRoomID
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(room.name)
                Text(Self.subtitle(for: room, closing: state.breakoutClosing == true, isCurrent: isCurrent))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)

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
            if !isCurrent, state.breakoutClosing != true, room.isOpen, room.joinURL != nil {
                Button("Join") { submit(CallActivity("joinRoom", resourceID: room.id), nil) }
                    .controlSize(.small)
                    .disabled(busy)
                    .accessibilityLabel("Join \(room.name)")
            }
        }
    }

    /// Room status and, when available, how many people are assigned.
    static func subtitle(
        for room: CallBreakoutRoom,
        closing: Bool = false,
        isCurrent: Bool = false
    ) -> String {
        let state = switch (closing, isCurrent, room.isOpen) {
        case (true, _, _): "Closing"
        case (_, true, _): "Current room"
        case (_, _, true): "Open"
        default: "Closed"
        }
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
