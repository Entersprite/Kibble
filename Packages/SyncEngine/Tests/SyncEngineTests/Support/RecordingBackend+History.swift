import ChatKit
@testable import ChatPersistence

extension RecordingBackend {
    /// Holds every later `loadMessages` in `abortableHistory`; a canceled one
    /// throws, as the wire's does.
    func holdHistory(_ hold: Bool) {
        holdingHistory = hold
    }
}
