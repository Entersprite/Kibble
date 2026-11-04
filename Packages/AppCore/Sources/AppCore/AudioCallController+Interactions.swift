import ChatKit
import Foundation

public extension AudioCallController {
    var isHandRaised: Bool {
        participants?.first(where: { $0.isLocal && !$0.isPresentation })?.handRaised == true
    }

    func toggleHandRaised() {
        guard let call, call.phase == .connected, !isEnding, !isUpdatingInteraction,
              interaction?.canRaiseHand == true,
              let interactions = service as? any CallInteractionService else { return }
        let epoch = generation
        let raised = !isHandRaised
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
