import ChatKit
import Foundation

public extension ChatSessionModel {
    func searchCallPeople(_ query: String) async throws -> [Member] {
        try Task.checkCancellation()
        let members = try await engine.searchPeople(query)
        try Task.checkCancellation()
        return members.filter { $0.kind == .human && $0.id != me }
    }
}
