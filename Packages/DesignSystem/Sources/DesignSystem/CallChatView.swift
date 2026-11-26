import ChatKit
import SwiftUI

public struct CallChatScene {
    public var messages: [Message]
    public var directory: [Member.ID: Member]
    public var me: Member.ID?
    public var draft: String
    public var isSending: Bool
    public var error: String?
    public var updateDraft: (String) -> Void
    public var send: (() -> Void)?
    public var open: () -> Void
    public var close: () -> Void

    public init(
        messages: [Message],
        directory: [Member.ID: Member],
        me: Member.ID?,
        draft: String,
        isSending: Bool,
        error: String?,
        updateDraft: @escaping (String) -> Void,
        send: (() -> Void)?,
        open: @escaping () -> Void,
        close: @escaping () -> Void
    ) {
        self.messages = messages; self.directory = directory; self.me = me
        self.draft = draft; self.isSending = isSending; self.error = error
        self.updateDraft = updateDraft; self.send = send; self.open = open; self.close = close
    }
}

/// One message as the call's chat draws it.
struct CallChatRow: Identifiable, Equatable {
    let id: Message.ID
    let text: String
    let isMine: Bool
    /// The sender's name, on the first of a run of someone else's messages.
    let sender: String?

    /// Call entries and deleted messages are left out; a name is shown once
    /// per run, and never over the person's own messages.
    static func rows(_ messages: [Message], directory: [Member.ID: Member], me: Member.ID?) -> [CallChatRow] {
        var rows: [CallChatRow] = []
        var previous: Member.ID?
        for message in messages where !message.isDeleted && message.callStatus == nil {
            let isMine = message.sender == me
            let named = !isMine && message.sender != previous
            rows.append(CallChatRow(
                id: message.id, text: message.text, isMine: isMine,
                sender: named ? Display.name(of: message.sender, in: directory) : nil
            ))
            previous = message.sender
        }
        return rows
    }
}

/// The conversation's messages beside the call: bubbles as in the
/// transcript, the newest at the bottom, and a field that sends on Return
/// and keeps the keyboard afterwards.
///
/// On its own it is the popover that hangs from the More button. `embedded`
/// is the same chat inside Meeting Activities, where it fills the pane it is
/// given and says where its messages are kept.
struct CallChatView: View {
    let scene: CallChatScene
    var embedded = false
    @FocusState private var isTyping: Bool

    var body: some View {
        let rows = CallChatRow.rows(scene.messages, directory: scene.directory, me: scene.me)
        VStack(spacing: 0) {
            if rows.isEmpty {
                ContentUnavailableView(
                    "No Messages", systemImage: "bubble.left.and.bubble.right",
                    description: Text(Self.emptyText(canSend: scene.send != nil))
                )
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(rows) { row in
                            CallChatBubble(row: row)
                        }
                    }
                    .padding(.horizontal, embedded ? 0 : 12)
                    .padding(.vertical, 10)
                }
                .defaultScrollAnchor(.bottom)
            }
            if let error = scene.error {
                CallChatNote(text: error, isWarning: true)
                    .padding(.horizontal, embedded ? 0 : 14)
                    .padding(.bottom, 6)
            }
            if let send = scene.send {
                CallChatComposer(
                    text: Binding(get: { scene.draft }, set: scene.updateDraft),
                    prompt: "Message", isSending: scene.isSending, isTyping: $isTyping, send: send
                )
                .padding(embedded ? .top : .all, embedded ? 4 : 10)
            } else if !rows.isEmpty {
                CallChatNote(text: "Chat is read-only in this meeting.")
                    .padding(.horizontal, embedded ? 0 : 14)
                    .padding(.bottom, embedded ? 0 : 10)
            }
            if embedded {
                Text("Messages are saved in the meeting’s conversation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
            }
        }
        .frame(width: embedded ? nil : 320, height: embedded ? nil : 400)
        .frame(maxHeight: embedded ? .infinity : nil)
        .onAppear {
            scene.open()
            isTyping = true
        }
        .onDisappear(perform: scene.close)
        .onChange(of: scene.isSending) { _, sending in
            // The field is disabled while a message is on its way, which
            // takes the keyboard from it; give it back.
            if !sending {
                isTyping = true
            }
        }
    }

    static func emptyText(canSend: Bool) -> String {
        canSend ? "Messages you send here go to the conversation." : "Nobody has sent a message yet."
    }
}

/// A line under a chat: what went wrong, or why there is no field.
struct CallChatNote: View {
    let text: String
    var isWarning = false

    var body: some View {
        Label {
            Text(text)
        } icon: {
            if isWarning {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            } else {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .foregroundStyle(isWarning ? .primary : .secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The field every chat in a call types into: plain text in a rounded well,
/// Return or the arrow sends, and nothing is sent while it is empty.
struct CallChatComposer: View {
    @Binding var text: String
    let prompt: String
    var isSending = false
    /// False while the meeting cannot take the message right now.
    var isEnabled = true
    var isTyping: FocusState<Bool>.Binding?
    let send: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            field
                .textFieldStyle(.plain)
                .lineLimit(1 ... 5)
                .disabled(isSending)
                .onSubmit {
                    if canSend {
                        send()
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            Button("Send", systemImage: "arrow.up.circle.fill", action: send)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .font(.title2)
                .tint(.accentColor)
                .disabled(!canSend)
                .help("Send")
        }
    }

    @ViewBuilder private var field: some View {
        if let isTyping {
            TextField(prompt, text: $text, axis: .vertical).focused(isTyping)
        } else {
            TextField(prompt, text: $text, axis: .vertical)
        }
    }

    private var canSend: Bool {
        isEnabled && !isSending && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private struct CallChatBubble: View {
    let row: CallChatRow

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let sender = row.sender {
                Text(sender)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 10)
                    .padding(.top, 6)
            }
            Text(row.text)
                .textSelection(.enabled)
                .foregroundStyle(row.isMine ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    row.isMine ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
        }
        // Room on the far side, so a long message still reads as one side's.
        .padding(row.isMine ? .leading : .trailing, 36)
        .frame(maxWidth: .infinity, alignment: row.isMine ? .trailing : .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.isMine ? "You: \(row.text)" : "\(row.sender ?? "") \(row.text)")
    }
}
