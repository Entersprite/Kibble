import Foundation
import Synchronization

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Only used for unary requests whose caller needs a definite pre-write failure.
final class RequestTransmissionObserver: NSObject, URLSessionTaskDelegate, Sendable {
    private let untransmitted = Mutex(false)

    var confirmedUntransmitted: Bool {
        untransmitted.withLock { $0 }
    }

    func urlSession(
        _: URLSession, task _: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        let transactions = metrics.transactionMetrics
        let neverStarted = metrics.redirectCount == 0 && !transactions.isEmpty && transactions.allSatisfy {
            $0.resourceFetchType == .networkLoad && !$0.isReusedConnection
                && $0.requestStartDate == nil && $0.requestEndDate == nil
                && $0.countOfRequestHeaderBytesSent == 0 && $0.countOfRequestBodyBytesSent == 0
                && $0.responseStartDate == nil && $0.response == nil
        }
        untransmitted.withLock { $0 = neverStarted }
    }
}
