import LocalBridgeBackend

public extension NativeCallMedia {
    func confirmAdmission(_ notices: [CallAdmissionNotice]) async -> Bool {
        let current = generation
        guard isConnected, !Task.isCancelled, !notices.isEmpty else { return false }
        let accepted = await admissionConfirmation(notices)
        return accepted && generation == current && isConnected && !Task.isCancelled
    }
}
