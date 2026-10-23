import ChatKit
import Foundation

public struct ConversationBrowserScene: Sendable, Equatable {
    public var page: String?
    public var lastPage: String?
    public var query = ""
    public var scope: SpaceDirectoryScope = .discover
    public var organization: SpaceDirectoryOrganization = .all
    public var people: [Member] = []
    public var pickerPeople: [Member] = []
    public var isSearchingPeople = false
    public var panelTarget: Conversation.ID?
    public var needsReconciliation = false
    public var spaces: [ConversationDetails] = []
    public var isLoading = false
    public var hasMore = false
    public var error: String?
    public var creationKind: Conversation.Kind?
    public var details: ConversationDetails?
    public var participants: [ConversationParticipant] = []
    public var hasMoreParticipants = false
    public var isLoadingParticipants = false
    public var panelError: String?
    public var isSubmitting = false
    public var notice: String?
    /// An unjoined conversation's recent messages, for its open panel.
    public var preview: ConversationPreview?
    public var isLoadingPreview = false
    public var previewError: String?

    public init() {}
}

@MainActor
public struct ConversationBrowserActions {
    public var show: (String) -> Void
    public var back: () -> Void
    public var search: (String, SpaceDirectoryScope?, Bool) -> Void
    public var reviewCreation: () -> Void
    public var setSpaceOrganization: (SpaceDirectoryOrganization) -> Void
    public var searchPeople: (String) -> Void
    public var beginCreation: (Conversation.Kind) -> Void
    public var create: (ConversationDraft) -> Void
    public var closePanel: () -> Void
    public var details: (Conversation.ID, Bool) -> Void
    public var preview: (ConversationDetails) -> Void
    public var mutate: (ConversationMutation) -> Void

    public init(
        show: @escaping (String) -> Void,
        back: @escaping () -> Void,
        search: @escaping (String, SpaceDirectoryScope?, Bool) -> Void,
        reviewCreation: @escaping () -> Void,
        searchPeople: @escaping (String) -> Void,
        beginCreation: @escaping (Conversation.Kind) -> Void,
        create: @escaping (ConversationDraft) -> Void,
        closePanel: @escaping () -> Void,
        details: @escaping (Conversation.ID, Bool) -> Void,
        preview: @escaping (ConversationDetails) -> Void,
        mutate: @escaping (ConversationMutation) -> Void,
        setSpaceOrganization: @escaping (SpaceDirectoryOrganization) -> Void = { _ in }
    ) {
        self.reviewCreation = reviewCreation; self
            .searchPeople = searchPeople; self.show = show; self.back = back; self.search = search
        self.beginCreation = beginCreation; self.create = create; self.closePanel = closePanel
        self.setSpaceOrganization = setSpaceOrganization
        self.details = details; self.preview = preview; self.mutate = mutate
    }
}
