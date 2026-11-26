import ChatKit
import Foundation

public extension AudioCallController {
    var isHandRaised: Bool {
        localHandIsRaised == true
    }

    var localHandIsRaised: Bool? {
        participants?.first(where: { $0.isLocal && !$0.isPresentation })?.handRaised
    }

    func toggleHandRaised() {
        setHandRaised(!isHandRaised)
    }

    func raiseHandIfLowered(in callID: UUID) {
        guard call?.id == callID, localHandIsRaised == false else { return }
        setHandRaised(true)
    }

    private func setHandRaised(_ raised: Bool) {
        guard let call, call.phase == .connected, !isEnding, !isUpdatingInteraction,
              interaction?.canRaiseHand == true,
              let interactions = service as? any CallInteractionService else { return }
        let epoch = generation
        isUpdatingInteraction = true
        interactionTask = Task { [weak self] in
            defer {
                if self?
                    .generation == epoch {
                    self?.isUpdatingInteraction = false; self?.interactionTask = nil
                }
            }
            do {
                try await interactions.setHandRaised(raised, callID: call.id)
            } catch {
                guard let self, !Task.isCancelled, generation == epoch, self.call?.id == call.id,
                      self.call?.phase == .connected else { return }
                self.call?.failureMessage = "The hand change could not be confirmed."
            }
        }
    }
}
