import ChatKit
import SwiftUI

/// A read-only transcript before joining. Its messages never become the
/// selected conversation and cannot publish read receipts or typing.
struct ConversationPreviewSheet: View {
    let details: ConversationDetails
    let state: ChatSceneState
    let actions: ConversationBrowserActions
    var media: ChatSceneActions?
    @State private var confirmingBlock = false

    private var title: String {
        Display.title(of: details.conversation, directory: state.directory, me: state.me)
    }

    private var previewState: ChatSceneState {
        var value = ChatSceneState(directory: state.directory, me: state.me)
        for member in state.browser.preview?.members ?? [] {
            value.directory[member.id] = member
        }
        return value
    }

    private var messages: [Message] {
        state.browser.preview?.messages ?? details.previewMessages
    }

    private var joining: ConversationMutation? {
        [.join, .acceptInvitation, .requestJoin].first { details.allowedActions.contains($0.action) }
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: title, message: ConversationDetailsText.subtitle(details)) {
                ConversationPicture(
                    conversation: details.conversation,
                    directory: state.directory,
                    me: state.me,
                    size: 40
                )
            }
            .padding(.bottom, 12)
            Divider()
            transcript
            if let error = state.browser.panelError {
                SheetErrorRow(message: error).font(.callout).padding(12)
            }
            if state.browser.needsReconciliation {
                Button("Reload Details") { actions.details(details.conversation.id, false) }
                    .padding(.bottom, 8)
            }
        }
        .frame(width: 560, height: 560)
        .toolbar {
            if details.allowedActions.contains("block") {
                ToolbarItem(placement: .destructiveAction) {
                    Button("Block…", role: .destructive) { confirmingBlock = true }
                        .disabled(state.browser.needsReconciliation)
                }
            }
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", action: actions.closePanel)
            }
            if let joining {
                ToolbarItem(placement: .confirmationAction) {
                    Button(joining == .requestJoin ? "Ask to Join" : "Join") { actions.mutate(joining) }
                        .disabled(state.browser.needsReconciliation)
                }
            }
        }
        .disabled(state.browser.isSubmitting)
        .onExitCommand(perform: actions.closePanel)
        .alert("Block “\(title)”?", isPresented: $confirmingBlock) {
            Button("Block", role: .destructive) { actions.mutate(.block) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You won’t receive messages or invitations from this space.")
        }
        .environment(\.openURL, LinkPolicy.openURLAction(blocking: state.capabilities.internalLinkHosts))
        .environment(\.openMessageReference, nil)
        .environment(\.loadMessageReference, nil)
        .environment(\.sceneImageLoader, media?.imageLoader)
    }

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                if let description = details.description, !description.isEmpty {
                    Text(description).font(.callout).foregroundStyle(.secondary).padding(.vertical, 8)
                }
                if state.browser.isLoadingPreview {
                    ProgressView("Loading Recent Messages…").frame(maxWidth: .infinity).padding()
                }
                if let error = state.browser.previewError {
                    VStack(alignment: .leading, spacing: 8) {
                        SheetErrorRow(message: error)
                        Button("Try Again") { actions.details(details.conversation.id, false) }
                    }
                    .font(.callout)
                }
                if messages.isEmpty, !state.browser.isLoadingPreview, state.browser.previewError == nil {
                    ContentUnavailableView("No Recent Messages", systemImage: "bubble.left.and.bubble.right")
                }
                ForEach(messages, id: \.id) { message in
                    MessageBubble(
                        message: message,
                        state: MessageRowState(message: message, scene: previewState, showsThread: false),
                        loadAttachment: media?.loadAttachment,
                        loadRemoteImage: media?.loadRemoteImage
                    )
                }
            }
            .padding(16)
        }
        .defaultScrollAnchor(.bottom)
    }
}
