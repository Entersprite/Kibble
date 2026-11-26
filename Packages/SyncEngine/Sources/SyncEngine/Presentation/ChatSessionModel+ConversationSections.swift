import ChatKit
import Foundation

public extension ChatSessionModel {
    func updateConversationSection(_ edit: ConversationSectionEdit) async throws {
        guard capabilities.canEditConversationSections else {
            throw ChatError.unsupported(capability: "editConversationSections")
        }
        guard edit.isValid, conversationSections.contains(where: { $0.id == edit.id }) else {
            throw ChatError.unknown("This section change is unavailable.")
        }
        try await performConversationSectionWrite { backend in
            try await backend.updateConversationSection(edit)
        } apply: { _ in
            if let index = conversationSections.firstIndex(where: { $0.id == edit.id }),
               let section = edit.applying(to: conversationSections[index]) {
                conversationSections[index] = section
            }
        }
    }

    func createConversationSection(named name: String) async throws {
        guard capabilities.canManageConversationSections else {
            throw ChatError.unsupported(capability: "manageConversationSections")
        }
        guard ConversationSection.isValidName(name)
        else { throw ChatError.unknown("Enter a valid section name.") }
        try await performConversationSectionWrite { backend in
            try await backend.createConversationSection(named: name)
        } apply: { section in
            if !removedConversationSectionIDs.contains(section.id),
               !conversationSections.contains(where: { $0.id == section.id }) {
                conversationSections.append(section)
            }
        }
    }

    func deleteConversationSection(_ id: String) async throws {
        guard capabilities.canManageConversationSections else {
            throw ChatError.unsupported(capability: "manageConversationSections")
        }
        guard conversationSections.contains(where: { $0.id == id }) else {
            throw ChatError.unknown("This section is no longer available.")
        }
        try await performConversationSectionWrite { backend in
            try await backend.deleteConversationSection(id)
        } apply: { _ in
            retireConversationSections([id])
        }
    }

    func moveSidebarConversation(_ placement: ConversationSectionPlacement) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await moveConversationToSection(placement)
            } catch is CancellationError {
                return
            } catch {
                lastError = .unknown("The section move could not be confirmed.")
            }
        }
    }

    func moveConversationToSection(_ placement: ConversationSectionPlacement) async throws {
        guard capabilities.canMoveConversationSections else {
            throw ChatError.unsupported(capability: "moveConversationSections")
        }
        guard placement.isValid, conversations.contains(where: { $0.id == placement.conversationID }),
              placement.sectionID == nil || conversationSections
                  .contains(where: { $0.id == placement.sectionID })
        else {
            throw ChatError.unknown("This conversation cannot be moved to a section.")
        }
        try await performConversationSectionWrite { backend in
            try await backend.moveConversationToSection(placement)
        } apply: { _ in
            if placement.sectionID == nil || conversationSections
                .contains(where: { $0.id == placement.sectionID }) {
                conversationSections = placement.applying(to: conversationSections)
            }
        }
    }

    private func performConversationSectionWrite<Value: Sendable>(
        _ perform: @escaping @Sendable (any ChatBackend) async throws -> Value,
        apply: (Value) -> Void
    ) async throws {
        try Task.checkCancellation()
        guard connectionState == .connected else { throw ChatError.notAuthenticated }
        guard conversationSectionWrite == nil else {
            throw ChatError.unknown("A section change is already in progress.")
        }
        cancelConversationSectionRead()
        let id = UUID()
        let task = Task { [engine] in try await engine.performConversationSectionWrite(perform) }
        conversationSectionWrite = (id, { task.cancel() })
        defer {
            if conversationSectionWrite?.id == id {
                conversationSectionWrite = nil
                refreshConversationSections()
            }
        }
        let value = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        try Task.checkCancellation()
        guard conversationSectionWrite?.id == id else { throw CancellationError() }
        apply(value)
    }
}

extension ChatSessionModel {
    func refreshConversationSections() {
        guard connectionState == .connected, capabilities.canReadConversationSections,
              conversationSectionTask == nil, conversationSectionWrite == nil else { return }
        conversationSectionTask = Task { [weak self, engine] in
            defer {
                if !Task.isCancelled {
                    self?.conversationSectionTask = nil
                }
            }
            repeat {
                self?.conversationSectionReadInvalidated = false
                let sections = try? await engine.loadConversationSections()
                guard let self, !Task.isCancelled else { return }
                if !conversationSectionReadInvalidated, let sections {
                    applyConversationSections(sections)
                }
            } while self?.conversationSectionReadInvalidated == true
        }
    }

    func refreshChangedConversationSections() async {
        guard capabilities.canReadConversationSections else { return }
        let removed = await engine.takeConversationSectionRemovals()
        guard !Task.isCancelled else { return }
        if !removed.isEmpty {
            retireConversationSections(removed)
        }
        if conversationSectionTask == nil {
            refreshConversationSections()
        } else {
            conversationSectionReadInvalidated = true
        }
    }

    private func retireConversationSections(_ removed: Set<String>) {
        removedConversationSectionIDs.formUnion(removed)
        conversationSections.removeAll { removed.contains($0.id) }
    }

    private func applyConversationSections(_ sections: [ConversationSection]) {
        removedConversationSectionIDs.formIntersection(sections.map(\.id))
        conversationSections = sections.filter { !removedConversationSectionIDs.contains($0.id) }
    }

    func cancelConversationSectionRead() {
        conversationSectionTask?.cancel()
        conversationSectionTask = nil
        conversationSectionReadInvalidated = false
    }

    func cancelConversationSectionWrite() {
        conversationSectionWrite?.cancel()
        conversationSectionWrite = nil
    }
}

extension SyncEngine {
    func performConversationSectionWrite<Value: Sendable>(
        _ perform: @Sendable (any ChatBackend) async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        let generation = managementGeneration
        let confirmed = try await perform(backend)
        try Task.checkCancellation()
        guard managementGeneration == generation else { throw CancellationError() }
        return confirmed
    }

    func loadConversationSections() async throws -> [ConversationSection]? {
        let generation = managementGeneration
        let version = conversationSectionVersion
        let sections = try await backend.conversationSections()
        try Task.checkCancellation()
        guard managementGeneration == generation else { throw CancellationError() }
        return version == conversationSectionVersion ? sections : nil
    }
}
