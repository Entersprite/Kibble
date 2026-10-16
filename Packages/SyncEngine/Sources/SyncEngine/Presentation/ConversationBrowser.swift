import ChatKit
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
    public private(set) var needsReconciliation = false
    public private(set) var spaces: [ConversationDetails] = []
    public private(set) var isLoading = false
    public private(set) var nextCursor: String?
    public private(set) var error: String?
    public private(set) var creationKind: Conversation.Kind?
    public private(set) var details: ConversationDetails?
    public private(set) var participants: [ConversationParticipant] = []
    public private(set) var participantCursor: String?
    public private(set) var panelError: String?
    public private(set) var isSubmitting = false
    public private(set) var notice: String?
    @ObservationIgnored var uncertainCreationKind: Conversation.Kind?
    @ObservationIgnored var onOpen: ((Conversation.ID) -> Void)?
    @ObservationIgnored let engine: SyncEngine
    @ObservationIgnored var queryTask: Task<Void, Never>?
    @ObservationIgnored var peopleTask: Task<Void, Never>?
    @ObservationIgnored var detailsTask: Task<Void, Never>?
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

    private func saveDirectory() {
        guard let page else { return }
        directorySnapshots[page] = ConversationDirectorySnapshot(
            query: query,
            scope: scope,
            organization: organization,
            people: people,
            spaces: spaces,
            cursor: nextCursor,
            error: error,
            wasLoading: isLoading
        )
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

    public func returnToDirectory() {
        if let lastPage {
            showPage(lastPage)
        }
    }

    public func beginCreation(_ kind: Conversation.Kind) {
        guard !isSubmitting else { return }
        detailsTask?.cancel()
        peopleTask?.cancel()
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
        isSearchingPeople = false
        panelTarget = nil
        needsReconciliation = false
        creationKind = nil
        details = nil
        participants = []
        panelError = nil
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
                notice = result.failedMembers.isEmpty ? nil
                    : "Created, but \(result.failedMembers.count) people could not be added."
                onOpen?(result.conversation.id)
                if !result.failedMembers.isEmpty {
                    openDetails(result.conversation.id)
                }
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

    public func openDetails(_ id: Conversation.ID, more: Bool = false) {
        detailsTask?.cancel()
        panelTarget = id
        needsReconciliation = true
        panelError = nil
        creationKind = nil
        let cursor = more ? participantCursor : nil
        if !more {
            if details?.conversation.id != id {
                details = nil
            }
            participants = []; participantCursor = nil
        }
        let generation = generation
        detailsTask = Task { [weak self, engine] in
            do {
                let detail = try await engine.loadConversationDetails(id)
                guard let self, !Task.isCancelled, !stopped, self.generation == generation else { return }
                details = detail
                needsReconciliation = false
                guard detail.membership == .joined else { return }
                let page = try await engine.loadParticipants(in: id, after: cursor)
                guard !Task.isCancelled, !stopped, self.generation == generation else { return }
                let existing = Set(participants.map(\.id))
                var seen = existing
                participants += page.participants.filter { seen.insert($0.id).inserted }
                participantCursor = page.nextCursor == cursor ? nil : page.nextCursor
                if more, page.participants.allSatisfy({ existing.contains($0.id) }),
                   participantCursor != nil {
                    participantCursor = nil
                    panelError = "The service repeated a page. Reload to see more people."
                }
            } catch {
                guard let self, !Task.isCancelled, !stopped, self.generation == generation else { return }
                panelError = Self.message(error)
            }
        }
    }

    public func showPreview(_ preview: ConversationDetails) {
        openDetails(preview.conversation.id)
    }

    func stop() {
        stopped = true
        generation += 1
        queryTask?.cancel(); peopleTask?.cancel(); detailsTask?.cancel(); writeTask?.cancel()
        queryTask = nil; detailsTask = nil; writeTask = nil
        directorySnapshots = [:]
        uncertainCreationKind = nil; panelTarget = nil; pickerPeople = []; page = nil; lastPage =
            nil; details = nil; creationKind = nil
        people = []; spaces = []; participants = []
        query = ""; error = nil; panelError = nil; notice = nil
        nextCursor = nil; participantCursor = nil; scope = .discover; organization = .all
        isSearchingPeople = false; needsReconciliation = false
        isLoading = false; isSubmitting = false
    }

    private static func message(_ error: any Error) -> String {
        if let error = error as? ChatError {
            return error.localizedDescription
        }
        return "The operation could not be completed. Please reload and try again."
    }
}

extension ConversationBrowser {
    public func mutate(_ mutation: ConversationMutation) {
        guard let details, !isSubmitting, !stopped, !needsReconciliation else { return }
        isSubmitting = true
        panelError = nil
        let generation = generation
        writeTask = Task { [weak self, engine] in
            do {
                let result = try await engine.mutateConversation(
                    mutation, in: details.conversation.id, operationID: UUID().uuidString,
                    expectedRevision: details.revision
                )
                guard let self, !Task.isCancelled, !stopped, self.generation == generation else { return }
                isSubmitting = false
                applyManagementResult(result, mutation: mutation, in: details.conversation.id)
            } catch {
                guard let self, !Task.isCancelled, !stopped, self.generation == generation else { return }
                isSubmitting = false
                needsReconciliation = true
                panelError = Self.message(error)
            }
        }
    }

    private func applyManagementResult(
        _ result: ConversationMutationResult,
        mutation: ConversationMutation,
        in id: Conversation.ID
    ) {
        guard result.isConfirmed else {
            needsReconciliation = true
            panelError = "The change could not be confirmed. Reload before trying again."
            return
        }
        if mutation == .leave || mutation == .deleteSpace || mutation == .declineInvitation {
            closePanel()
        } else if details?.conversation.id == id {
            if let updated = result.details {
                details = updated
            }
            if !result.failedMembers.isEmpty {
                notice = "\(result.failedMembers.count) people could not be updated."
            }
            if result.details == nil || result.details?.membership == .joined {
                openDetails(id)
            }
        }
        if page == "space" || page == "spaceSpam" {
            search(query, scope: scope)
        }
    }
}

struct ConversationDirectorySnapshot {
    var query: String
    var scope: SpaceDirectoryScope
    var organization: SpaceDirectoryOrganization
    var people: [Member]
    var spaces: [ConversationDetails]
    var cursor: String?
    var error: String?
    var wasLoading: Bool
}
