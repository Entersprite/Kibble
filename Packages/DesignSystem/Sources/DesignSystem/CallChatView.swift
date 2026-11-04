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

struct CallChatView: View {
    let scene: CallChatScene
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Chat").font(.headline)
            ScrollViewReader { _ in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(
                            scene.messages.filter { !$0.isDeleted && $0.callStatus == nil },
                            id: \.id
                        ) { message in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(Display.name(of: message.sender, in: scene.directory))
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(message.text).textSelection(.enabled)
                            }
                            .id(message.id)
                            .frame(
                                maxWidth: .infinity,
                                alignment: message.sender == scene.me ? .trailing : .leading
                            )
                        }
                    }
                }
                .defaultScrollAnchor(.bottom)
            }
            if let error = scene.error {
                Text(error).font(.callout).foregroundStyle(.secondary)
            }
            if let send = scene.send {
                HStack {
                    TextField(
                        "Message",
                        text: Binding(get: { scene.draft }, set: scene.updateDraft),
                        axis: .vertical
                    )
                    .lineLimit(1 ... 5)
                    .textFieldStyle(.roundedBorder)
                    .disabled(scene.isSending)
                    Button(action: send) { Label("Send", systemImage: "arrow.up") }.labelStyle(.iconOnly)
                        .disabled(scene.isSending || scene.draft
                            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(16).frame(width: 340, height: 420)
        .onAppear(perform: scene.open)
        .onDisappear(perform: scene.close)
    }
}
