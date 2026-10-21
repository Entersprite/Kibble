import ChatKit

extension LocalBridgeBackend {
    func reportResourceFailure(_ resource: ResourceSyncStatus.Resource, error: ChatError) {
        let status = ResourceSyncStatus(resource: resource, phase: .failed, error: error)
        guard resourceFailures[resource] != status else { return }
        resourceFailures[resource] = status
        emit(.resourceSyncChanged(status))
    }

    func resourceRecovered(_ resource: ResourceSyncStatus.Resource) {
        guard resourceFailures.removeValue(forKey: resource) != nil else { return }
        emit(.resourceSyncChanged(.init(resource: resource, phase: .ready)))
    }
}
