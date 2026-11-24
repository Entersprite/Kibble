import ChatKit
import SwiftUI

struct CallMeetingActivityChat: View {
    let scene: CallActivitiesScene
    @Binding var message: String
    @Binding var waitingRoomMessage: String
    let busy: Bool
    let submit: (CallActivity, (() -> Void)?) -> Void
    @State private var chatForWaitingRoom = false

    var body: some View {
        if scene.state.availableActions.contains("chatWaitingRoom") {
            Picker("Recipient", selection: $chatForWaitingRoom) {
                Text("Everyone").tag(false)
                Text("Waiting room").tag(true)
            }
            if chatForWaitingRoom {
                waitingRoomChat
            } else {
                everyoneChat
            }
        } else {
            everyoneChat
        }
    }

    @ViewBuilder private var everyoneChat: some View {
        if let meetingChat = scene.meetingChat {
            CallChatView(scene: meetingChat, embedded: true).id(scene.state.meetingChat?.conversationID)
        } else {
            chat
        }
    }

    private var waitingRoomChat: some View {
        VStack(alignment: .leading, spacing: 12) {
            CallWaitingRoomMessages(messages: scene.state.waitingRoomMessages ?? [])
            Divider()
            HStack(alignment: .bottom) {
                TextField("Message the waiting room", text: $waitingRoomMessage, axis: .vertical)
                    .lineLimit(1 ... 5)
                Button("Send to Waiting Room", systemImage: "paperplane") {
                    let text = waitingRoomMessage
                    submit(CallActivity("chatWaitingRoom", text: text)) {
                        if waitingRoomMessage == text {
                            waitingRoomMessage = ""
                        }
                    }
                }.disabled(!can("chatWaitingRoom")
                    || waitingRoomMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    var chat: some View {
        VStack(alignment: .leading, spacing: 12) {
            if scene.state.messages.isEmpty {
                Text("No meeting messages yet.").foregroundStyle(.secondary)
            }
            ForEach(
                scene.state.messages.filter { $0.isPinned == true }
                    + scene.state.messages.filter { $0.isPinned != true }
            ) { entry in
                CallMeetingChatMessageRow(
                    message: entry,
                    showsPinAction: scene.state.availableActions.contains("setMeetingMessagePin")
                ) {
                    submit(CallActivity(
                        "setMeetingMessagePin",
                        resourceID: entry.id,
                        enabled: entry.isPinned != true
                    ), nil)
                }
            }
            Divider()
            HStack(alignment: .bottom) {
                TextField("Message everyone", text: $message, axis: .vertical).lineLimit(1 ... 5)
                Button("Send", systemImage: "paperplane") {
                    let text = message
                    submit(CallActivity("chat", text: text)) {
                        if message == text {
                            message = ""
                        }
                    }
                }.disabled(!can("chat") || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func can(_ action: String) -> Bool {
        !busy && scene.state.availableActions.contains(action)
    }
}

struct CallWaitingRoomMessages: View {
    let messages: [CallMeetingMessage]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if messages.isEmpty {
                Text("No waiting-room messages yet.").foregroundStyle(.secondary)
            }
            ForEach(messages) { message in
                VStack(alignment: .leading, spacing: 2) {
                    Text(message.sender).font(.caption).foregroundStyle(.secondary)
                    Text(message.text).textSelection(.enabled)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CallWaitingRoomGuestMessages: View {
    let messages: [CallMeetingMessage]?

    var body: some View {
        if let messages, !messages.isEmpty {
            ScrollView {
                CallWaitingRoomMessages(messages: messages).padding(8)
            }
            .frame(maxHeight: 94)
            .accessibilityLabel("Messages from the meeting hosts")
        }
    }
}
