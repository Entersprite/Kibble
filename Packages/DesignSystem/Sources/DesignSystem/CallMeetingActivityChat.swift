import ChatKit
import SwiftUI

/// The Chat section of Meeting Activities: the meeting's messages, pinned
/// ones first, and a field under them. A host who may write to the waiting
/// room chooses who a message goes to above the messages; each audience
/// keeps its own messages and its own draft.
struct CallMeetingActivityChat: View {
    let scene: CallActivitiesScene
    @Binding var message: String
    @Binding var waitingRoomMessage: String
    let busy: Bool
    let submit: (CallActivity, (() -> Void)?) -> Void
    @State private var chatForWaitingRoom = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if offers("chatWaitingRoom") {
                Picker("Send To", selection: $chatForWaitingRoom) {
                    Text("Everyone").tag(false)
                    Text("Waiting Room").tag(true)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                if chatForWaitingRoom {
                    waitingRoomChat
                } else {
                    everyoneChat
                }
            } else {
                everyoneChat
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private var everyoneChat: some View {
        if let meetingChat = scene.meetingChat {
            CallChatView(scene: meetingChat, embedded: true).id(scene.state.meetingChat?.conversationID)
        } else {
            chat
        }
    }

    private var waitingRoomChat: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                CallWaitingRoomMessages(messages: scene.state.waitingRoomMessages ?? [])
            }
            .defaultScrollAnchor(.bottom)
            CallChatComposer(
                text: $waitingRoomMessage, prompt: "Message the waiting room",
                isEnabled: can("chatWaitingRoom")
            ) {
                let text = waitingRoomMessage
                submit(CallActivity("chatWaitingRoom", text: text)) {
                    // Only what was sent is cleared; typing since then stays.
                    if waitingRoomMessage == text {
                        waitingRoomMessage = ""
                    }
                }
            }
            Text("People in the waiting room can read these but can’t reply.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    var chat: some View {
        VStack(alignment: .leading, spacing: 8) {
            let messages = scene.state.messages
            if messages.isEmpty {
                ContentUnavailableView(
                    "No Messages", systemImage: "bubble.left.and.bubble.right",
                    description: Text("Messages here last as long as the meeting.")
                )
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(
                            messages.filter { $0.isPinned == true } + messages.filter { $0.isPinned != true }
                        ) { entry in
                            CallMeetingChatMessageRow(
                                message: entry, showsPinAction: offers("setMeetingMessagePin"),
                                isBusy: busy
                            ) {
                                submit(CallActivity(
                                    "setMeetingMessagePin", resourceID: entry.id,
                                    enabled: entry.isPinned != true
                                ), nil)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if offers("chat") {
                CallChatComposer(text: $message, prompt: "Message everyone", isEnabled: can("chat")) {
                    let text = message
                    submit(CallActivity("chat", text: text)) {
                        if message == text {
                            message = ""
                        }
                    }
                }
            } else if !messages.isEmpty {
                CallChatNote(text: "Chat is read-only in this meeting.")
            }
        }
    }

    private func offers(_ action: String) -> Bool {
        scene.state.availableActions.contains(action)
    }

    private func can(_ action: String) -> Bool {
        !busy && offers(action)
    }
}

/// Messages sent to the waiting room: who sent each, and what it said.
struct CallWaitingRoomMessages: View {
    let messages: [CallMeetingMessage]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if messages.isEmpty {
                Text("No messages to the waiting room yet.").foregroundStyle(.secondary)
            }
            ForEach(messages) { message in
                VStack(alignment: .leading, spacing: 2) {
                    Text(message.sender).font(.caption).foregroundStyle(.secondary)
                    Text(message.text).textSelection(.enabled)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// What the hosts wrote to someone still waiting to be let in, above the
/// call's controls: read-only, on glass like the window's other notices.
struct CallWaitingRoomGuestMessages: View {
    let messages: [CallMeetingMessage]?

    var body: some View {
        if let messages, !messages.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("From the Hosts")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                ScrollView {
                    CallWaitingRoomMessages(messages: messages)
                }
                .defaultScrollAnchor(.bottom)
                .frame(maxHeight: 84)
            }
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: 320, alignment: .leading)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Messages from the meeting hosts")
        }
    }
}
