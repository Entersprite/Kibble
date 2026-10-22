import ChatKit
import ChatPersistence
import Foundation

/// Your own status and availability while a choice is in flight.
@MainActor
final class OwnStatusWork {
    var availability = OptimisticChoice<Availability?>(observed: nil)
    var status = OptimisticChoice<MemberStatus?>(observed: nil)
}

/// Setting your own status and availability (set-your-status spec §4).
///
/// Shown at once: the menu, the footer and the account panel draw the choice
/// before the service answers, and only a refused or uncertain command puts
/// the previous value back, with the reason in `lastError` through
/// `SyncEngine.submit`. This replaces the spec's §7, which waited for the
/// answer so nothing would spring back; with the account service in between,
/// that wait was long enough to read as lag.
public extension ChatSessionModel {
    func setStatus(_ status: MemberStatus?) {
        let token = ownStatusWork.status.choose(status)
        showOwnStatus()
        submitStatusCommand(.setStatus(status)) { [weak self] accepted in
            self?.ownStatusWork.status.settle(token, accepted: accepted)
            self?.showOwnStatus()
        }
    }

    func setAvailability(_ availability: Availability) {
        let token = ownStatusWork.availability.choose(availability)
        self.availability = ownStatusWork.availability.shown
        submitStatusCommand(.setAvailability(availability)) { [weak self] accepted in
            guard let self else { return }
            ownStatusWork.availability.settle(token, accepted: accepted)
            self.availability = ownStatusWork.availability.shown
        }
    }

    /// Whether this device is in use (active-presence spec §5). A hint: a
    /// backend that cannot keep you active ignores it.
    func reportActivity(_ active: Bool) {
        submitStatusCommand(.reportActivity(active: active))
    }

    private func submitStatusCommand(
        _ command: ChatCommand, answered: (@MainActor (Bool) -> Void)? = nil
    ) {
        let taskID = UUID()
        sendTasks[taskID] = Task { @MainActor [weak self, engine] in
            defer { self?.sendTasks.removeValue(forKey: taskID) }
            guard !Task.isCancelled else { return }
            let accepted = await engine.submit(command)
            guard !Task.isCancelled else { return }
            answered?(accepted)
        }
    }
}

extension ChatSessionModel {
    /// Your own row in `directory`, as stored or as just chosen.
    func showOwnStatus() {
        guard let me, directory[me] != nil else { return }
        let shown = ownStatusWork.status.shown
        if directory[me]?.status != shown {
            directory[me]?.status = shown
        }
    }

    /// A store delivery of your own status. The store's value is recorded
    /// first, so a refusal restores what the store last said.
    func observeOwnStatus(in members: inout [Member.ID: Member]) {
        guard let me, let own = members[me] else { return }
        ownStatusWork.status.observe(own.status)
        members[me]?.status = ownStatusWork.status.shown
    }
}
