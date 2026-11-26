import ChatKit
import ChatService

extension SQLiteAccountStorage: ServiceCallHistoryStorage {
    public func callHistory(_ query: CallHistoryQuery) throws -> CallHistoryPage {
        try projection.callHistory(query)
    }
}
