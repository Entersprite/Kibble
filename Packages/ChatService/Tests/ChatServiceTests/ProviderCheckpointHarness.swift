import ChatKit
import Foundation
@testable import ChatService

extension ReconciliationBackend {
    func usesProviderCheckpoints() -> Bool {
        checkpointing
    }

    func connect(resumingProviderCheckpoint: Data?) {
        resumedCheckpoint = resumingProviderCheckpoint
        providerBatchSink.yield(ProviderEventBatch(
            id: "fixture-connected", events: [.connectionStateChanged(.connected)],
            previousCheckpoint: resumingProviderCheckpoint, checkpoint: resumingProviderCheckpoint
        ))
    }

    func observeAcknowledgements(_ observer: @escaping @Sendable (String) -> Void) {
        acknowledgementObserver = observer
    }

    func acknowledgeProviderBatch(_ id: String) {
        acknowledgementObserver?(id)
        acknowledgedBatches.append(id)
    }

    func deliverBatch(_ batch: ProviderEventBatch) {
        providerBatchSink.yield(batch)
    }
}
