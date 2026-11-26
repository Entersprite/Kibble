import ChatAPI
import ChatKit

public extension ServiceBackend {
    func conversationSections() async throws -> [ConversationSection]? {
        try await call(GetConversationSections()).sections
    }

    func updateConversationSection(_ edit: ConversationSectionEdit) async throws {
        _ = try await call(UpdateConversationSection(
            edit: edit, operationID: ServiceOperationID(ClientOperationID.make())
        ))
    }

    func createConversationSection(named name: String) async throws -> ConversationSection {
        try await call(CreateConversationSection(
            name: name, operationID: ServiceOperationID(ClientOperationID.make())
        ))
    }

    func deleteConversationSection(_ id: String) async throws {
        _ = try await call(DeleteConversationSection(
            id: id, operationID: ServiceOperationID(ClientOperationID.make())
        ))
    }

    func moveConversationToSection(_ placement: ConversationSectionPlacement) async throws {
        _ = try await call(MoveConversationToSection(
            placement: placement, operationID: ServiceOperationID(ClientOperationID.make())
        ))
    }
}
