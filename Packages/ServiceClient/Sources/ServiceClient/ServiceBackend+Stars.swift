import ChatAPI
import ChatKit

public extension ServiceBackend {
    func starredMessages(after cursor: String?) async throws -> StarredMessagesPage {
        try await call(GetStarredMessages(cursor: cursor))
    }

    func setMessageStarred(_ starred: Bool, at address: MessageAddress) async throws {
        _ = try await call(SetMessageStarred(
            address: address, starred: starred, operationID: ServiceOperationID(ClientOperationID.make())
        ))
    }
}
