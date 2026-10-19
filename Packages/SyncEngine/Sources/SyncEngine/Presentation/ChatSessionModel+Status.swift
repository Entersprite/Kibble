import ChatKit
import ChatPersistence
import Foundation

/// Setting your own status and availability (set-your-status spec §4).
/// Commands, not requests: the answer comes back as events, and a refusal
/// lands in `lastError` through `SyncEngine.submit`. Nothing is shown before
/// the answer, so nothing has to spring back (spec §7).
public extension ChatSessionModel {
    func setStatus(_ status: MemberStatus?) {
        submitStatusCommand(.setStatus(status))
    }

    func setAvailability(_ availability: Availability) {
        submitStatusCommand(.setAvailability(availability))
    }

    /// Whether this device is in use (active-presence spec §5). A hint: a
    /// backend that cannot keep you active ignores it.
    func reportActivity(_ active: Bool) {
        submitStatusCommand(.reportActivity(active: active))
    }

    private func submitStatusCommand(_ command: ChatCommand) {
        let taskID = UUID()
        sendTasks[taskID] = Task { @MainActor [weak self, engine] in
            defer { self?.sendTasks.removeValue(forKey: taskID) }
            guard !Task.isCancelled else { return }
            await engine.submit(command)
        }
    }
}
