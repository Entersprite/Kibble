import AppCore
import Foundation
import SyncEngine

extension MacAppDelegate {
    static func guestChatAction(
        callID: UUID, environment: AppEnvironment, model: ChatSessionModel,
        showChat: @escaping @MainActor () -> Void
    ) -> (@MainActor (UUID) async throws -> Void)? {
        guard model.capabilities.canOpenDirectConversations else { return nil }
        return { [weak environment, weak model] guestID in
            guard let environment, let model else { throw CancellationError() }
            let calls = environment.calls
            @MainActor func currentAddress() -> String? {
                guard calls.call?.id == callID, calls.call?.phase == .connected, !calls.isEnding,
                      case let .running(current) = environment.phase, current === model else { return nil }
                return calls.interaction?.activities?.agendaGuests?.first { $0.id == guestID }?.chatAddress
            }
            guard let address = currentAddress() else { throw CancellationError() }
            try await model.openCallGuestChat(to: address) { currentAddress() == address }
            try Task.checkCancellation()
            guard currentAddress() == address else { throw CancellationError() }
            showChat()
        }
    }
}
