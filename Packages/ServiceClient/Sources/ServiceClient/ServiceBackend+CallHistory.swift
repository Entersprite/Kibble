import ChatAPI
import ChatKit

extension ServiceBackend: CallHistoryBackend {
    public func callHistory(_ query: CallHistoryQuery = .init()) async throws -> CallHistoryPage {
        try await call(ReadCallHistory(query: query))
    }
}
