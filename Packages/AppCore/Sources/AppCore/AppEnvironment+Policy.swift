import ChatAPI
import ChatKit
import ServiceClient

extension AppEnvironment {
    func startPolicyReplica() async {
        guard let policyReplica, policyTask == nil else { return }
        let cache = policyReplica.cache
        policyTask = Task { [weak self] in
            var sequence: UInt64?
            for await snapshot in cache.snapshots() {
                guard !Task.isCancelled else { return }
                if let sequence, sequence >= snapshot.sequence {
                    continue
                }
                sequence = snapshot.sequence
                self?.policyStatus = snapshot
                self?.applyPolicySnapshot()
            }
        }
        await policyReplica.start()
    }

    func stopPolicyReplica() async {
        policyReplica?.cache.close()
        settings.refreshPrivacy()
        policyTask?.cancel()
        await policyTask?.value
        policyTask = nil
        await policyReplica?.stop()
        policyStatus = nil
    }

    func applyPolicySnapshot() {
        guard let policyReplica else { return }
        let snapshot = policyReplica.cache.snapshot
        policyStatus = snapshot
        settings.applyReplica(snapshot.settings, for: policyReplica.cache.binding.identity)
    }
}

public extension AppEnvironment {
    var isPolicyReady: Bool {
        // Read the observed status for presentation invalidation, then check
        // the synchronous fence for an edit made before its delivery arrives.
        guard let policyReplica else { return true }
        return policyStatus?.isReady == true && settings.account == policyReplica.cache.binding.identity &&
            policyReplica.cache.isReady
    }

    func policyRevisionChanged(_ revision: String?) {
        policyReplica?.cache.invalidate(revision: revision)
        // Withhold immediately, including before the async observation runs.
        settings.refreshPrivacy()
    }

    func policyControlAvailable(_ available: Bool) {
        policyReplica?.cache.setControlAvailable(available)
        settings.refreshPrivacy()
    }
}
