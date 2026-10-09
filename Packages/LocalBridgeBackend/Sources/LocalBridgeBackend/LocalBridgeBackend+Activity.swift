import ChatKit
import Foundation
import GChatBridgeCore

/// `ChatCommand.reportActivity` (active-presence spec §3): while the device
/// is in use, every `presencePollInterval` (120 s, purple's figure for both
/// its presence poll and its activity timer), one `heartbeat` and one channel
/// ping saying you are active; when it stops, one of each saying you are not.
///
/// Kibble used to say "active" once, at connect, and Google turned it away
/// after its own timeout (`[Verify]`). Every send is a hint repeated within
/// two minutes, so a failure is dropped: neither thrown nor emitted.
extension LocalBridgeBackend {
    func reportActivity(_ inUse: Bool) {
        let wasInUse = presencePoll.deviceInUse
        presencePoll.deviceInUse = inUse
        if inUse {
            startActivityReports()
            return
        }
        presencePoll.activityTask?.cancel()
        presencePoll.activityTask = nil
        if wasInUse {
            Task { await sendActivity(active: false) }
        }
    }

    /// Only while connected and in use, only once, and only after this
    /// connect's self-identification, so your availability is known before
    /// the first report. `resolveAndEmitSelf` calls it when that finishes, so a
    /// report made before then, or kept across a stopped channel, starts there.
    func startActivityReports() {
        guard presencePoll.deviceInUse, presencePoll.selfResolved, presencePoll.activityTask == nil,
              apiClient != nil
        else { return }
        let interval = presencePollInterval
        presencePoll.activityTask = Task { [weak self] in
            while !Task.isCancelled {
                // `nil` once the backend has gone, which ends the loop.
                guard await self?.reportActivityRound() != nil else { return }
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
            }
        }
    }

    /// One round of the loop: a report, then the count tests wait on. A
    /// round canceled while it reported is not counted, so a stopped loop
    /// cannot count into the next connect's poll.
    private func reportActivityRound() async {
        await sendActivity(active: true)
        if !Task.isCancelled {
            presencePoll.activityRounds += 1
        }
    }

    /// One `heartbeat` and one channel ping. Nothing active under Away or a
    /// Do not disturb still running: your setting wins.
    func sendActivity(active: Bool) async {
        guard let apiClient else { return }
        if active, !ActivityRequests.reportsActive(under: presencePoll.ownAvailability, now: Date()) {
            return
        }
        _ = try? await apiClient.call(.heartbeat, ActivityRequests.heartbeat(active: active))
        await channel?.sendActivityPing(active: active)
    }
}
