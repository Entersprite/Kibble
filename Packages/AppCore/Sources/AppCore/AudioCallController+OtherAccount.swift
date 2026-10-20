import ChatKit

/// Calls on several accounts share this Mac's microphone and speaker, so a
/// ring on one account while another account is in a call is answered only
/// by ending that call. Only the person's choice ends it; a ring never does.
public extension AudioCallController {
    /// Whether this account's call holds the device: from the moment it
    /// connects until its end is confirmed. A ring holds nothing.
    var holdsDevice: Bool {
        isEnding || call.map { !$0.phase.isTerminal && $0.phase != .incoming } == true
    }

    /// Answers this ring after ending `other`'s call, once the service has
    /// confirmed that call's end and released the device. A ring that stops
    /// in the meantime is not answered.
    func accept(ending other: AudioCallController) async {
        guard other !== self, let id = call?.id, call?.phase == .incoming, !isEnding else { return }
        other.hangUp()
        await other.endingTask?.value
        guard call?.id == id, call?.phase == .incoming else { return }
        guard other.call?.phase == .ended || other.call?.phase == .declined,
              other.call?.failureMessage == nil, !other.isEnding else {
            recordHandoffFailure(id: id)
            return
        }
        accept()
    }
}
