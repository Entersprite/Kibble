import ChatKit
import SwiftUI

struct CallActivityRoomsView: View {
    let state: CallActivitiesState
    let busy: Bool
    @Binding var roomNames: String
    let submit: (CallActivity, (() -> Void)?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(state.rooms) { room in
                HStack {
                    Text(room.name); Spacer(); Text(room.isOpen ? "Open" : "Closed")
                        .foregroundStyle(.secondary)
                    Menu("Assign") {
                        ForEach(state.people) { person in
                            Button {
                                var request = CallActivity("assignRoom", resourceID: room.id)
                                request.participantIDs = room.participants.contains(person.id) ?
                                    room.participants.filter { $0 != person.id } : room
                                    .participants + [person.id]
                                submit(request, nil)
                            } label: {
                                Label(
                                    person.name,
                                    systemImage: assignmentSymbol(person.id, in: room)
                                )
                            }
                        }
                    }.disabled(!can("assignRoom"))
                    if room.isOpen, room.joinURL != nil {
                        Button("Join") { submit(CallActivity("joinRoom", resourceID: room.id), nil) }
                            .disabled(busy)
                    }
                }
            }
            if can("returnToMainRoom") {
                Button("Return to Main Room") { submit(CallActivity("returnToMainRoom"), nil) }
            }
            TextField("Room names, one per line", text: $roomNames, axis: .vertical).lineLimit(2 ... 10)
            Button("Create Rooms") {
                submit(CallActivity("createRooms", options: lines(roomNames))) { roomNames = "" }
            }
            .disabled(!can("createRooms") || !(1 ... 10).contains(lines(roomNames).count))
            HStack {
                Button("Open Rooms") { submit(CallActivity("openRooms"), nil) }
                    .disabled(!can("openRooms") || state.rooms.isEmpty)
                Button("Close Rooms") { submit(CallActivity("closeRooms"), nil) }
                    .disabled(!can("closeRooms") || state.rooms.isEmpty)
            }
        }
    }

    private func assignmentSymbol(_ person: UUID, in room: CallBreakoutRoom) -> String {
        room.participants.contains(person) ? "checkmark" : "person"
    }

    private func can(_ action: String) -> Bool {
        !busy && state.availableActions.contains(action)
    }

    private func lines(_ text: String) -> [String] {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
