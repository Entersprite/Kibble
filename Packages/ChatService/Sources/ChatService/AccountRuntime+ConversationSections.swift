import ChatAPI
import ChatKit
import Foundation

extension AccountRuntime {
    func dispatchConversationSections(
        _ request: ServiceRequest, backend: any ChatBackend, epoch: UUID
    ) async throws -> JSONValue {
        switch request.operation {
        case GetConversationSections.operation:
            try await readConversationSections(request, backend: backend, epoch: epoch)
        case UpdateConversationSection.operation:
            try await updateConversationSection(request, backend: backend, epoch: epoch)
        case MoveConversationToSection.operation:
            try await moveConversationToSection(request, backend: backend, epoch: epoch)
        case CreateConversationSection.operation, DeleteConversationSection.operation:
            try await changeConversationSections(request, backend: backend, epoch: epoch)
        default:
            throw ServiceFailure.unsupportedOperation
        }
    }

    private func moveConversationToSection(
        _ request: ServiceRequest, backend: any ChatBackend, epoch: UUID
    ) async throws -> JSONValue {
        guard capabilities.canMoveConversationSections else { throw ServiceFailure.unsupportedOperation }
        let payload = try request.decodePayload(MoveConversationToSection.self)
        guard payload.placement.isValid else { throw ServiceFailure.invalidRequest }
        let result = try await performOperation(payload.operationID, request: request, epoch: epoch) {
            try await backend.moveConversationToSection(payload.placement)
            return ServiceUnit()
        }
        try checkEpoch(epoch)
        return result
    }

    private func changeConversationSections(
        _ request: ServiceRequest, backend: any ChatBackend, epoch: UUID
    ) async throws -> JSONValue {
        guard capabilities.canManageConversationSections else { throw ServiceFailure.unsupportedOperation }
        let result: JSONValue
        if request.operation == CreateConversationSection.operation {
            let payload = try request.decodePayload(CreateConversationSection.self)
            guard ConversationSection.isValidName(payload.name) else { throw ServiceFailure.invalidRequest }
            result = try await performOperation(payload.operationID, request: request, epoch: epoch) {
                let section = try await backend.createConversationSection(named: payload.name)
                guard ConversationSection.isValidID(section.id), section.name == payload.name,
                      section.conversationIDs.isEmpty else { throw ServiceFailure.invalidResponse }
                return section
            }
        } else {
            let payload = try request.decodePayload(DeleteConversationSection.self)
            guard ConversationSection.isValidID(payload.id) else { throw ServiceFailure.invalidRequest }
            result = try await performOperation(payload.operationID, request: request, epoch: epoch) {
                try await backend.deleteConversationSection(payload.id)
                return ServiceUnit()
            }
        }
        try checkEpoch(epoch)
        return result
    }

    private func updateConversationSection(
        _ request: ServiceRequest, backend: any ChatBackend, epoch: UUID
    ) async throws -> JSONValue {
        guard capabilities.canEditConversationSections else { throw ServiceFailure.unsupportedOperation }
        let payload = try request.decodePayload(UpdateConversationSection.self)
        guard payload.edit.isValid else { throw ServiceFailure.invalidRequest }
        let result = try await performOperation(payload.operationID, request: request, epoch: epoch) {
            try await backend.updateConversationSection(payload.edit)
            return ServiceUnit()
        }
        try checkEpoch(epoch)
        return result
    }

    private func readConversationSections(
        _ request: ServiceRequest, backend: any ChatBackend, epoch: UUID
    ) async throws -> JSONValue {
        guard capabilities.canReadConversationSections else { throw ServiceFailure.unsupportedOperation }
        _ = try request.decodePayload(GetConversationSections.self)
        let sections = try await withProviderWork(epoch: epoch) {
            try await backend.conversationSections()
        }
        try checkEpoch(epoch)
        if let sections {
            guard sections.count <= 200, Set(sections.map(\.id)).count == sections.count,
                  sections.reduce(0, { $0 + $1.conversationIDs.count }) <= 8192,
                  sections.allSatisfy(Self.isValidConversationSection) else {
                throw ServiceFailure.invalidResponse
            }
        }
        return try ServiceCodec.value(ConversationSectionsResult(sections: sections))
    }

    private static func isValidConversationSection(_ section: ConversationSection) -> Bool {
        ConversationSection.isValidID(section.id) && ConversationSection.isValidID(section.name)
            && section.conversationIDs.allSatisfy {
                !$0.rawValue.isEmpty && $0.rawValue.utf8.count <= 512 && !$0.rawValue.contains("\0")
            }
    }
}
