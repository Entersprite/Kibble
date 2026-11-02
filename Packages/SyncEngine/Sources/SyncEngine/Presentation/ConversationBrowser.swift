import ChatKit
import ChatPersistence
import Foundation
import Observation

/// Account-owned directory and editor work. Preview results never select or populate a transcript.
@MainActor @Observable
public final class ConversationBrowser {
    public var page: String?
    public private(set) var lastPage: String?
    public private(set) var query = ""
    @ObservationIgnored var directorySnapshots: [String: ConversationDirectorySnapshot] = [:]
    public private(set) var scope: SpaceDirectoryScope = .discover
    public private(set) var organization: SpaceDirectoryOrganization = .all
    public private(set) var people: [Member] = []
    public private(set) var pickerPeople: [Member] = []
    public private(set) var isSearchingPeople = false
    public private(set) var panelTarget: Conversation.ID?
    public internal(set) var needsReconciliation = false
    public private(set) var spaces: [ConversationDetails] = []
    public private(set) var isLoading = false
    public private(set) var nextCursor: String?
    public private(set) var error: String?
    public private(set) var creationKind: Conversation.Kind?
    public internal(set) var details: ConversationDetails?
    public private(set) var participants: [ConversationParticipant] = []
    public private(set) var participantCursor: String?
    /// A people page is on its way: the People tab says so instead of
    /// standing empty under its member count.
    public private(set) var isLoadingParticipants = false
    public internal(set) var panelError: String?
    public internal(set) var isSubmitting = false
    public internal(set) var notice: String?
    public internal(set) var integrations: ConversationIntegrations?
    public internal(set) var isLoadingIntegrations = false
    public internal(set) var integrationsError: String?
    public internal(set) var appResults: [ConversationApp] = []
    public internal(set) var isSearchingApps = false
    public internal(set) var email: ConversationEmail?
    public internal(set) var isLoadingEmail = false
    public internal(set) var emailError: String?
    public internal(set) var conversion: ConversionConsequences?
    public internal(set) var isLoadingConversion = false
    public internal(set) var conversionError: String?
    public internal(set) var isLoadingAllParticipants = false
    /// The change on its way and its conversation; cleared when its answer or failure lands.
    var pendingChange: (conversation: Conversation.ID, mutation: ConversationMutation)?
    @ObservationIgnored var infoTasks: [ConversationInfoRead: Task<Void, Never>] = [:]
    @ObservationIgnored var uncertainCreationKind: Conversation.Kind?
    @ObservationIgnored var onOpen: ((Conversation.ID) -> Void)?
    @ObservationIgnored let engine: SyncEngine
    @ObservationIgnored var queryTask: Task<Void, Never>?
    @ObservationIgnored var peopleTask: Task<Void, Never>?
    @ObservationIgnored var detailsTask: Task<Void, Never>?
    @ObservationIgnored let previewState = ConversationPreviewModel()
    @ObservationIgnored var writeTask: Task<Void, Never>?
    @ObservationIgnored var generation = 0
    @ObservationIgnored var stopped = false

    init(engine: SyncEngine) {
        self.engine = engine
    }

    public func showPage(_ id: String) {
        saveDirectory()
        queryTask?.cancel()
        isLoading = false
        page = id
        lastPage = id
        if let saved = directorySnapshots[id] {
            query = saved.query; scope = saved.scope; organization = saved.organization; people = saved
                .people; spaces = saved.spaces
            nextCursor = saved.cursor; error = saved.error
            if saved.wasLoading {
                search(query, scope: scope)
            }
        } else {
            search(
                "",
                scope: id == "spaceSpam" ? .spamInvitations : id == "space" ? .discover : nil,
                organization: .all
            )
        }
    }

    func leaveDirectory() {
        saveDirectory()
        queryTask?.cancel()
        isLoading = false
        page = nil
    }

    public func search(
        _ text: String, scope: SpaceDirectoryScope? = nil,
        organization: SpaceDirectoryOrganization? = nil, more: Bool = false
    ) {
        queryTask?.cancel()
        if let scope {
            self.scope = scope
        }
        self.organization = organization ?? self.organization
        query = text
        error = nil
        let cursor = more ? nextCursor : nil
        if !more {
            nextCursor = nil; people = []; spaces = []
        }
        let page = page
        let query = SpaceDirectoryQuery(scope: self.scope, text: text, organization: self.organization)
        let generation = generation
        isLoading = true
        queryTask = Task { [weak self, engine] in
            do {
                try await Task.sleep(for: .milliseconds(text.isEmpty ? 0 : 200))
                if page == "space" || page == "spaceSpam" {
                    let result = try await engine.browseSpaces(query, after: cursor)
                    guard let self, !Task.isCancelled, !stopped, self.generation == generation else { return }
                    let existing = Set(spaces.map(\.conversation.id))
                    var seen = existing
                    spaces += result.spaces.filter { seen.insert($0.conversation.id).inserted }
                    nextCursor = result.nextCursor == cursor ? nil : result.nextCursor
                    if more, result.spaces.allSatisfy({ existing.contains($0.conversation.id) }),
                       nextCursor != nil {
                        nextCursor = nil
                        error = "The service repeated a page. Reload to see more spaces."
                    }
                } else if !text.isEmpty, page == "people" || page == "directMessage" {
                    let result = try await engine.searchConversationPeople(text)
                    guard let self, !Task.isCancelled, !stopped, self.generation == generation else { return }
                    people = result
                }
                guard let self, !Task.isCancelled, self.generation == generation else { return }
                isLoading = false
            } catch {
                guard let self, !Task.isCancelled, !stopped, self.generation == generation else { return }
                self.error = Self.message(error)
                isLoading = false
            }
        }
    }

    public func returnToDirectory() {
        if let lastPage {
            showPage(lastPage)
        }
    }

    public func beginCreation(_ kind: Conversation.Kind) {
        guard !isSubmitting else { return }
        detailsTask?.cancel()
        peopleTask?.cancel()
        forgetPreview()
        forgetInfo()
        isSearchingPeople = false
        details = nil
        panelTarget = nil
        needsReconciliation = uncertainCreationKind != nil
        creationKind = kind
        panelError = uncertainCreationKind == nil ? nil
            : "A previous creation could not be confirmed. Review your conversations before creating another."
        notice = nil
        pickerPeople = []
    }

    public func closePanel() {
        guard !isSubmitting else { return }
        detailsTask?.cancel()
        peopleTask?.cancel()
        forgetPreview()
        isSearchingPeople = false
        panelTarget = nil
        needsReconciliation = false
        creationKind = nil
        details = nil
        participants = []
        isLoadingParticipants = false
        panelError = nil
        notice = nil
        forgetInfo()
    }

    public func create(_ draft: ConversationDraft) {
        guard !isSubmitting, !stopped, !needsReconciliation else { return }
        isSubmitting = true
        panelError = nil
        let generation = generation
        writeTask = Task { [weak self, engine] in
            do {
                let result: ConversationCreationResult
                if draft.kind == .directMessage, let person = draft.members.first {
                    guard let conversation = await engine.openDirectConversation(with: person) else {
                        throw ChatError.unknown("The conversation could not be opened.")
                    }
                    result = ConversationCreationResult(conversation: conversation)
                } else {
                    result = try await engine.createConversation(draft)
                }
                guard let self, !Task.isCancelled, !stopped, self.generation == generation else { return }
                isSubmitting = false
                creationKind = nil
                if panelTarget != nil {
                    // Opened from Info: the new conversation shows, not the sheet over it.
                    closePanel()
                }
                onOpen?(result.conversation.id)
                // After opening, which clears another panel's notice.
                if !result.failedMembers.isEmpty {
                    openDetails(result.conversation.id)
                }
                notice = result.failedMembers.isEmpty ? nil
                    : "Created, but \(result.failedMembers.count) people could not be added."
            } catch {
                guard let self, !Task.isCancelled, !stopped, self.generation == generation else { return }
                isSubmitting = false
                uncertainCreationKind = draft.kind
                needsReconciliation = true
                panelError = Self.message(error)
            }
        }
    }

    public func reviewCreation() {
        guard let kind = uncertainCreationKind, !isSubmitting else { return }
        isSubmitting = true
        let generation = generation
        writeTask = Task { [weak self, engine] in
            do {
                try await engine.reloadConversationDirectory()
                guard let self, !Task.isCancelled, !stopped, self.generation == generation else { return }
                isSubmitting = false
                uncertainCreationKind = nil
                closePanel()
                showPage(kind == .space ? "space" : kind == .groupDirectMessage ? "groupDirectMessage" :
                    "directMessage")
            } catch {
                guard let self, !Task.isCancelled, !stopped, self.generation == generation else { return }
                isSubmitting = false
                panelError = Self.message(error)
            }
        }
    }

    /// Opens Info for `id`. Another conversation waits until the write on
    /// its way has landed: the open panel keeps its draft and its answer.
    public func openDetails(_ id: Conversation.ID, more: Bool = false) {
        guard !isSubmitting || panelTarget == id else { return }
        detailsTask?.cancel()
        let cursor = more ? participantCursor : nil
        retarget(to: id, more: more)
        let generation = generation
        detailsTask = Task { [weak self, engine] in
            do {
                let detail = try await engine.loadConversationDetails(id)
                guard let self, !Task.isCancelled, !stopped, self.generation == generation else { return }
                details = detail
                needsReconciliation = false
                guard detail.membership == .joined else {
                    participants = []; participantCursor = nil
                    isLoadingParticipants = false
                    if !more {
                        loadPreview(id)
                    }
                    return
                }
                forgetPreview()
                isLoadingParticipants = true
                let page = try await engine.loadParticipants(in: id, after: cursor)
                guard !Task.isCancelled, !stopped, self.generation == generation else { return }
                isLoadingParticipants = false
                let existing = Set(participants.map(\.id))
                var seen = more ? existing : []
                let incoming = page.participants.filter { seen.insert($0.id).inserted }
                participants = more ? participants + incoming : incoming
                participantCursor = page.nextCursor == cursor ? nil : page.nextCursor
                if more, page.participants.allSatisfy({ existing.contains($0.id) }),
                   participantCursor != nil {
                    participantCursor = nil
                    panelError = "The service repeated a page. Reload to see more people."
                }
            } catch {
                guard let self, !Task.isCancelled, !stopped, self.generation == generation else { return }
                isLoadingParticipants = false
                panelError = Self.message(error)
            }
        }
    }

    /// The panel's state as a details read for `id` begins: another
    /// conversation's notice, preview and Info reads go. Same-conversation
    /// rows stay visible until the first page replaces them.
    private func retarget(to id: Conversation.ID, more: Bool) {
        if panelTarget != id {
            notice = nil
            participants = []; participantCursor = nil
        }
        if !more {
            forgetPreview()
        }
        panelTarget = id
        needsReconciliation = true
        isLoadingParticipants = true
        panelError = nil
        creationKind = nil
        if !more {
            if details?.conversation.id != id {
                details = nil
                forgetInfo()
            }
        }
    }

    public func showPreview(_ preview: ConversationDetails) {
        openDetails(preview.conversation.id)
    }
}

extension ConversationBrowser {
    /// Keep an acknowledged role visible until the authoritative People read arrives.
    func retainConfirmedRole(_ mutation: ConversationMutation, result: ConversationMutationResult) {
        guard result.isConfirmed, case let .setRole(id, role) = mutation,
              !result.failedMembers.contains(id),
              let index = participants.firstIndex(where: { $0.id == id }) else { return }
        participants[index].role = role
    }

    /// Retire earlier reads even when the provider ignores cancellation.
    func retirePanelReadsForMutation() {
        detailsTask?.cancel(); detailsTask = nil
        peopleTask?.cancel(); peopleTask = nil
        isLoadingParticipants = false
        isSearchingPeople = false
    }

    /// Refresh People permissions without replacing confirmed details or blocking edits.
    func refreshSettingsParticipants(_ id: Conversation.ID) {
        detailsTask?.cancel()
        isLoadingParticipants = true
        let generation = generation
        detailsTask = Task { [weak self, engine] in
            do {
                let page = try await engine.loadParticipants(in: id, after: nil)
                guard let self, !Task.isCancelled, !stopped, self.generation == generation,
                      panelTarget == id else { return }
                participants = page.participants
                participantCursor = page.nextCursor
                isLoadingParticipants = false
            } catch {
                guard let self, !Task.isCancelled, !stopped, self.generation == generation,
                      panelTarget == id else { return }
                isLoadingParticipants = false
                panelError = Self.message(error)
            }
        }
    }

    public func searchPeople(_ text: String) {
        peopleTask?.cancel()
        if !needsReconciliation {
            panelError = nil
        }
        pickerPeople = []
        isSearchingPeople = !text.isEmpty
        guard !text.isEmpty else { return }
        let generation = generation
        peopleTask = Task { [weak self, engine] in
            do {
                try await Task.sleep(for: .milliseconds(200))
                let result = try await engine.searchConversationPeople(text)
                guard let self, !Task.isCancelled, !stopped, self.generation == generation else { return }
                pickerPeople = result
                isSearchingPeople = false
            } catch {
                guard let self, !Task.isCancelled, !stopped, self.generation == generation else { return }
                panelError = Self.message(error)
                isSearchingPeople = false
            }
        }
    }

    func stop() {
        stopped = true
        generation += 1
        queryTask?.cancel(); peopleTask?.cancel(); detailsTask?.cancel(); writeTask?.cancel()
        queryTask = nil; detailsTask = nil; writeTask = nil
        forgetPreview()
        directorySnapshots = [:]
        uncertainCreationKind = nil; panelTarget = nil; pickerPeople = []; page = nil; lastPage =
            nil; details = nil; creationKind = nil
        people = []; spaces = []; participants = []
        query = ""; error = nil; panelError = nil; notice = nil
        nextCursor = nil; participantCursor = nil; scope = .discover; organization = .all
        isSearchingPeople = false; needsReconciliation = false; isLoadingParticipants = false
        isLoading = false; isSubmitting = false; pendingChange = nil
        forgetInfo()
    }
}
