import ChatKit

/// Optional canonical read port. A storage implementation without this port
/// does not advertise retained call history.
public protocol ServiceCallHistoryStorage: Sendable {
    func callHistory(_ query: CallHistoryQuery) throws -> CallHistoryPage
}
