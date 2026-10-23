import ChatKit
import DesignSystem
import SyncEngine

extension AppEnvironment {
    func browserScene(_ model: ChatSessionModel) -> ConversationBrowserScene {
        let browser = model.browser
        var state = ConversationBrowserScene()
        state.page = browser.page
        state.lastPage = browser.lastPage
        state.query = browser.query
        state.scope = browser.scope
        state.organization = browser.organization
        state.people = browser.people
        state.pickerPeople = browser.pickerPeople
        state.isSearchingPeople = browser.isSearchingPeople
        state.panelTarget = browser.panelTarget
        state.needsReconciliation = browser.needsReconciliation
        state.spaces = browser.spaces
        state.isLoading = browser.isLoading
        state.hasMore = browser.nextCursor != nil
        state.error = browser.error
        state.creationKind = browser.creationKind
        state.details = browser.details
        state.participants = browser.participants
        state.hasMoreParticipants = browser.participantCursor != nil
        state.isLoadingParticipants = browser.isLoadingParticipants
        state.panelError = browser.panelError
        state.isSubmitting = browser.isSubmitting
        state.notice = browser.notice
        state.preview = browser.preview
        state.isLoadingPreview = browser.isLoadingPreview
        state.previewError = browser.previewError
        return state
    }

    /// File › New Message…, New Group Chat… and New Space…: offered only
    /// where the running backend can do what the sidebar's + would.
    public func canBeginConversation(_ kind: NewConversationKind) -> Bool {
        guard let capabilities = runningModel?.capabilities else { return false }
        return kind == .message ? capabilities.canOpenDirectConversations
            : capabilities.canCreateConversations
    }

    public func beginConversation(_ kind: NewConversationKind) {
        guard canBeginConversation(kind) else { return }
        runningModel?.beginConversationCreation(kind.conversationKind)
    }

    var browserActions: ConversationBrowserActions? {
        guard let model = runningModel else { return nil }
        return ConversationBrowserActions(
            show: { [weak model] in model?.showConversationDirectory($0) },
            back: { [weak model] in
                guard let model, model.browser.lastPage != nil else { return }
                model.returnToConversationDirectory()
            },
            search: { [weak model] in model?.browser.search($0, scope: $1, more: $2) },
            reviewCreation: { [weak model] in model?.reviewConversationCreation() },
            searchPeople: { [weak model] in model?.browser.searchPeople($0) },
            beginCreation: { [weak model] in model?.beginConversationCreation($0) },
            create: { [weak model] in model?.browser.create($0) },
            closePanel: { [weak model] in model?.browser.closePanel() },
            details: { [weak model] in model?.browser.openDetails($0, more: $1) },
            preview: { [weak model] in model?.browser.showPreview($0) },
            mutate: { [weak model] in model?.browser.mutate($0) },
            setSpaceOrganization: { [weak model] in
                guard let model else { return }
                model.browser.search(model.browser.query, organization: $0)
            }
        )
    }
}

/// What the menu bar's File › New items start, named here so the app shell
/// needs no domain types.
public enum NewConversationKind: Sendable {
    case message, groupChat, space

    var conversationKind: Conversation.Kind {
        switch self {
        case .message: .directMessage
        case .groupChat: .groupDirectMessage
        case .space: .space
        }
    }
}
